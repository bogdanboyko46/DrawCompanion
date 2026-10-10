// Turns what the user just said + a photo of their page into an action on
// the outline. The microphone is always on and the AI never talks back: it
// only draws, changes, or clears the outline, or ignores speech that isn't
// meant for it. Claude decides where things go; there is no user-placed box.

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
  placement: z
    .object({ x: z.number(), y: z.number(), w: z.number(), h: z.number() })
    .describe("Bounding box of the suggestion in paper units"),
  strokes: z.array(Stroke),
});

const Response = z.object({
  action: z
    .enum(["new", "revise", "hide", "ignore"])
    .describe(
      "new = draw a new suggestion (replaces any current one); revise = change the current suggestion; hide = clear the current suggestion; ignore = the speech isn't a request to you",
    ),
  note: z.string().describe("A few words for the developer log on why. Never shown to the user."),
  suggestion: Suggestion.nullable().describe("Required for new and revise; null for hide and ignore"),
});

const SYSTEM = `You are DrawCompanion, a silent drawing assistant inside an AR headset.
The user is drawing on real paper. Their microphone is always on and they talk freely: to you, to themselves, or to other people. You never reply in words. Your only output is an action on the outline that is projected onto their paper for them to trace.

Each turn you get a top-down, perspective-corrected photo of their page with a faint labeled coordinate grid (paper units; origin top-left, x right, y down), what they just said, and the outline currently shown (if any). The black-and-white squares in the corners and at the middle of the side edges are tracking markers: ignore them and never draw over them.

Choosing the action:
- new: they are asking for something to be drawn ("add a cat on the windowsill", "I'm stuck, what goes here?", "give me something else").
- revise: they want the CURRENT outline changed ("bigger", "make it face left", "move it up a bit", "no, a pine tree"). Change what they asked for and keep everything else.
- hide: they want the outline gone ("clear it", "I've got it", "never mind").
- ignore: anything else (thinking aloud, talking to someone else, describing what they're doing, filler words, unclear fragments). When in doubt between ignore and drawing something they didn't ask for, ignore.

Choosing where it goes (it's entirely your call):
- Read the drawing: what's there, its perspective, scale, and where the composition has room. Put the suggestion where it makes sense for the scene and the request ("on the windowsill" means on the drawn windowsill). Use empty space; never cover existing work unless they asked to change it.
- Connect to existing lines where natural (a branch starts on the trunk; a hand attaches to the wrist) and match the size of neighboring objects.

How to draw it:
- Continue THEIR drawing. Match subject matter, scale, perspective, line weight, and level of detail. A loose sketch gets a loose suggestion; a careful study gets careful lines.
- Prefer fewer, confident strokes. Start with construction strokes (simple shapes that set size and placement), then contours, then a little detail. Skip shading unless asked. If they ask for just guidelines, use only construction strokes.
- Coordinates must be accurate: use the grid labels to place points. Points must stay inside the page.`;

let client;

// utterances: what they said since the last action (oldest first).
// current: { suggestion, history } for the outline on the page, or null.
export async function decide({ imageBase64, mediaType, paper, utterances, current, signal }) {
  client ??= new Anthropic();
  const lines = [`Page size: ${paper.w} x ${paper.h} paper units.`];
  if (current) {
    lines.push(
      "Outline currently shown:",
      JSON.stringify(current.suggestion),
      "It was drawn from these requests, oldest first:",
      ...current.history.map((u) => `- "${u}"`),
    );
  } else {
    lines.push("No outline is currently shown.");
  }
  lines.push("They just said, oldest first:", ...utterances.map((u) => `- "${u}"`));

  let response;
  try {
    response = await client.beta.messages.parse(
      {
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
              { type: "text", text: lines.join("\n") },
            ],
          },
        ],
      },
      { signal },
    );
  } catch (err) {
    // Output that doesn't match the schema surfaces as a plain AnthropicError;
    // API failures and aborts are subclasses and propagate to the caller.
    if (err instanceof Anthropic.AnthropicError && !(err instanceof Anthropic.APIError)) {
      throw new SuggestError("malformed outline");
    }
    throw err;
  }

  if (response.stop_reason === "refusal") return { action: "ignore", note: "declined", suggestion: null };
  if (!response.parsed_output) throw new SuggestError(`no output (stop_reason: ${response.stop_reason})`);
  return sanitize(response.parsed_output, paper);
}

export class SuggestError extends Error {}

// The model is good but not perfect at geometry: clamp to the page and drop
// degenerate strokes. A drawing action without usable strokes becomes ignore.
export function sanitize(result, paper) {
  if (result.action !== "new" && result.action !== "revise") return { ...result, suggestion: null };
  const clampPt = ([x, y]) => [clamp(x, 0, paper.w), clamp(y, 0, paper.h)];
  const strokes = (result.suggestion?.strokes ?? [])
    .map((st) => ({
      ...st,
      points: st.points.filter((p) => p.length >= 2 && p.every(Number.isFinite)).map(clampPt),
    }))
    .filter((st) => st.points.length >= 2);
  if (!strokes.length) return { action: "ignore", note: `${result.note} (no usable strokes)`, suggestion: null };
  return { ...result, suggestion: { ...result.suggestion, strokes } };
}

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
