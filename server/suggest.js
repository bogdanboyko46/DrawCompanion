// Turns "a photo of my paper + what I'm stuck on" into a traceable outline.
//
// Claude acts as the art director: it reads the drawing (subject, style,
// line weight, palette, empty space) and returns vector strokes in paper
// coordinates. Strokes are grouped by role so the client can show
// construction lines first, then contours, then detail.

import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { z } from "zod";

const MODEL = process.env.DRAWCOMPANION_MODEL || "claude-opus-5-5";
// Latency matters more than depth here: the user is mid-drawing, waiting.
const EFFORT = process.env.DRAWCOMPANION_EFFORT || "low";

const Stroke = z.object({
  role: z
    .enum(["construction", "contour", "detail", "shading"])
    .describe(
      "construction = proportion/perspective guides (circles, boxes, center lines); contour = main silhouette; detail = interior lines; shading = hatching hints",
    ),
  points: z
    .array(z.array(z.number()))
    .describe("Polyline as [x, y] pairs in paper units. 4–60 points; densify curves."),
  closed: z.boolean(),
  weight: z.enum(["light", "medium", "bold"]),
});

const Suggestion = z.object({
  title: z.string().describe("2–5 word name, e.g. 'Fox curled on the rock'"),
  placement: z
    .object({ x: z.number(), y: z.number(), w: z.number(), h: z.number() })
    .describe("Bounding box of the suggestion in paper units"),
  strokes: z.array(Stroke),
  palette: z
    .array(z.object({ hex: z.string(), use: z.string() }))
    .describe("2–5 colors that match the existing drawing; 'use' says where each goes"),
  steps: z.array(z.string()).describe("2–4 short instructions, in drawing order"),
});

const Response = z.object({
  understood: z
    .string()
    .describe("One sentence: what you think the user wants and what you see on the page"),
  style_notes: z.string().describe("Medium, line quality, and style you are matching"),
  suggestions: z.array(Suggestion),
});

const SYSTEM = `You are DrawCompanion, a drawing assistant that lives in an AR headset.
The user is drawing on real paper and is stuck. You see a top-down, perspective-corrected photo of their page with a faint labeled coordinate grid (paper units; origin top-left, x right, y down). The black-and-white squares in the corners and at the middle of the side edges are tracking markers: ignore them and never draw over them. You reply with vector strokes that are projected onto the paper for them to trace.

How to make a good suggestion:
- Continue THEIR drawing. Match subject matter, scale, perspective, line weight, and level of detail. A loose sketch gets a loose suggestion; a careful study gets careful lines.
- When the user marks a box, that box is where the suggestion goes: fill it (the suggestion's bounding box should nearly match the box) and make it fit what is around the box: connect to lines that touch it, match the perspective and scale of neighboring objects.
- Without a box, place the suggestion in empty space, never on top of existing work unless they asked to modify it. Connect to existing lines where natural (a branch starts on the trunk; a hand attaches to the wrist).
- Prefer fewer, confident strokes over many. Start with construction strokes (simple shapes that set size and placement), then contours, then a little detail. Skip shading unless asked.
- Coordinates must be accurate: use the grid labels to place points. Points must stay inside the page.
- Palette: pick colors already present in the drawing first; add at most one complementary color.
- When revising after feedback, change what the feedback asks for and keep everything else (placement, size, style) the same unless told otherwise.
- If the request is vague ("what should I add?"), propose what would most improve the piece (balance, focal point, story) and say why in 'understood'.`;

let client;

// revision (optional): { previous: <a suggestion we returned>, feedback: [strings, oldest first] }
export async function suggest({ imageBase64, mediaType, request, mode, region, paper, revision }) {
  client ??= new Anthropic();
  const count = mode === "options" && !revision ? 3 : 1;
  const regionText = region
    ? `The user marked a box for the suggestion: x=${r(region.x)}, y=${r(region.y)}, w=${r(region.w)}, h=${r(region.h)}.`
    : "No box marked: choose the best placement.";
  const modeText = {
    outline: "Give one suggestion with construction, contour and detail strokes.",
    scaffold:
      "Give one suggestion using ONLY construction strokes (shapes, center lines, perspective guides). The user wants to draw the final lines themselves.",
    options:
      "Give exactly 3 different suggestions (different ideas, not small variations), each lighter on detail so they can be previewed side by side.",
  }[mode] ?? "";

  const lines = [
    `Page size: ${paper.w} x ${paper.h} paper units.`,
    regionText,
    revision ? "" : modeText,
    `User request: "${request || "I'm stuck, what should I add?"}"`,
  ];
  if (revision) {
    lines.push(
      `You already suggested this (the photo may show they have started drawing it):`,
      JSON.stringify(revision.previous),
      `They want changes. Feedback, oldest first:`,
      ...revision.feedback.map((f) => `- "${f}"`),
      mode === "scaffold"
        ? "Return one revised suggestion, still using ONLY construction strokes."
        : "Return one revised suggestion.",
    );
  }
  const userText = lines.filter(Boolean).join("\n");

  let response;
  try {
    response = await client.beta.messages.parse({
      model: MODEL,
      max_tokens: 16000,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      output_config: { effort: EFFORT, format: betaZodOutputFormat(Response) },
      system: SYSTEM,
      messages: [
        {
          role: "user",
          content: [
            { type: "image", source: { type: "base64", media_type: mediaType, data: imageBase64 } },
            { type: "text", text: userText },
          ],
        },
      ],
    });
  } catch (err) {
    // Output that doesn't match the schema surfaces as a plain AnthropicError;
    // API failures are APIError subclasses and propagate to the caller.
    if (err instanceof Anthropic.AnthropicError && !(err instanceof Anthropic.APIError)) {
      throw new SuggestError("The outline came back malformed. Please try again.");
    }
    throw err;
  }

  if (response.stop_reason === "refusal") {
    throw new SuggestError("The request was declined. Try rephrasing it.");
  }
  if (!response.parsed_output) {
    throw new SuggestError(`No usable suggestion (stop_reason: ${response.stop_reason}).`);
  }
  return sanitize(response.parsed_output, paper, count);
}

export class SuggestError extends Error {}

// The model is good but not perfect at geometry: clamp to the page, drop
// degenerate strokes, and cap the number of suggestions.
export function sanitize(result, paper, count = 1) {
  const clampPt = ([x, y]) => [clamp(x, 0, paper.w), clamp(y, 0, paper.h)];
  const suggestions = result.suggestions.slice(0, count).map((s) => ({
    ...s,
    strokes: s.strokes
      .map((st) => ({
        ...st,
        points: st.points.filter((p) => p.length >= 2 && p.every(Number.isFinite)).map(clampPt),
      }))
      .filter((st) => st.points.length >= 2),
    palette: s.palette.filter((c) => /^#[0-9a-f]{6}$/i.test(c.hex)).slice(0, 5),
  }));
  return { ...result, suggestions: suggestions.filter((s) => s.strokes.length > 0) };
}

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
const r = Math.round;
