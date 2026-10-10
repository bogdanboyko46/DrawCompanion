// Turns what the user just said + a photo of their page into an action on
// the outline. The microphone is always on and the AI never talks back: it
// only draws, changes, or clears the outline, or ignores speech that isn't
// meant for it. Claude decides where things go; there is no user-placed box.
//
// Two stages, because most of what an always-on microphone hears is chatter:
//   1. filter (Claude Haiku, text only): new | revise | hide | ignore.
//      Fast and nearly free; most phrases stop here.
//   2. draw (Claude Opus, with the page photo): only for new / revise.

import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { z } from "zod";

const FILTER_MODEL = process.env.DRAWCOMPANION_FILTER_MODEL || "claude-haiku-5-5";
const DRAW_MODEL = process.env.DRAWCOMPANION_DRAW_MODEL || "claude-opus-5-5";
// Latency matters more than depth here: the user is mid-drawing, waiting.
const DRAW_EFFORT = process.env.DRAWCOMPANION_DRAW_EFFORT || "low";

// ---------- stage 1: is this meant for us, and what do they want? ----------

const Decision = z.object({
  action: z
    .enum(["new", "revise", "hide", "ignore"])
    .describe(
      "new = draw something new (replaces any current outline); revise = change the current outline; hide = clear the current outline; ignore = not a request to the assistant",
    ),
  note: z.string().describe("A few words for the developer log on why. Never shown to the user."),
});

const FILTER_SYSTEM = `You are the listening filter for DrawCompanion, a silent drawing assistant in an AR headset.
The user draws on real paper. Their microphone is always on and they talk freely: to the assistant, to themselves, or to other people. The assistant never replies in words; it can only draw an outline on their paper, change it, or clear it. You decide, from what they just said, which of these to do.

- new: they are asking for something to be drawn or suggested ("add a cat on the windowsill", "I'm stuck, what goes here?", "give me something else", "what if there was a tree").
- revise: an outline is currently shown and they want it changed ("bigger", "make it face left", "move it up a bit", "no, a pine tree"). Only possible when an outline is shown.
- hide: an outline is currently shown and they want it gone ("clear it", "I've got it", "never mind"). Only possible when an outline is shown.
- ignore: anything else: thinking aloud, talking to someone else, describing what they're doing, comments that don't ask for anything, filler words, unclear fragments.

When unsure whether they want something drawn, choose ignore: drawing something nobody asked for is worse than missing a request, since they can just ask again.`;

export async function classify({ client, utterances, current, signal }) {
  const lines = current
    ? ["An outline is currently shown. It was drawn from these requests, oldest first:", ...quote(current.history)]
    : ["No outline is currently shown."];
  lines.push("They just said, oldest first:", ...quote(utterances));

  const response = await parse(
    client,
    {
      model: FILTER_MODEL,
      max_tokens: 2000, // leaves room for thinking before the short answer
      output_config: { effort: "low", format: betaZodOutputFormat(Decision) },
      system: FILTER_SYSTEM,
      messages: [{ role: "user", content: lines.join("\n") }],
    },
    signal,
  );
  // Haiku has no server-side fallback; a declined phrase is simply not acted on.
  if (response.stop_reason === "refusal" || !response.parsed_output) {
    return { action: "ignore", note: `filter: ${response.stop_reason}` };
  }
  const { action, note } = response.parsed_output;
  if (!current && action === "revise") return { action: "new", note };
  if (!current && action === "hide") return { action: "ignore", note };
  return { action, note };
}

// ---------- stage 2: draw it ----------

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

const DRAW_SYSTEM = `You are DrawCompanion, a silent drawing assistant inside an AR headset.
The user is drawing on real paper and asked (out loud) for help. You never reply in words. Your only output is an outline, as vector strokes, that is projected onto their paper for them to trace.

You get a top-down, perspective-corrected photo of their page with a faint labeled coordinate grid (paper units; origin top-left, x right, y down), what they said, and the outline currently shown (if any). The black-and-white squares in the corners and at the middle of the side edges are tracking markers: ignore them and never draw over them.

Choosing where it goes (it's entirely your call):
- Read the drawing: what's there, its perspective, scale, and where the composition has room. Put the suggestion where it makes sense for the scene and the request ("on the windowsill" means on the drawn windowsill). Use empty space; never cover existing work unless they asked to change it.
- Connect to existing lines where natural (a branch starts on the trunk; a hand attaches to the wrist) and match the size of neighboring objects.

How to draw it:
- Continue THEIR drawing. Match subject matter, scale, perspective, line weight, and level of detail. A loose sketch gets a loose suggestion; a careful study gets careful lines.
- Prefer fewer, confident strokes. Start with construction strokes (simple shapes that set size and placement), then contours, then a little detail. Skip shading unless asked. If they ask for just guidelines, use only construction strokes.
- When revising, change what they asked for and keep everything else (placement, size, style) the same.
- Coordinates must be accurate: use the grid labels to place points. Points must stay inside the page.`;

export async function draw({ client, imageBase64, mediaType, paper, utterances, current, action, signal }) {
  const lines = [`Page size: ${paper.w} x ${paper.h} paper units.`];
  if (action === "revise") {
    lines.push(
      "Outline currently shown:",
      JSON.stringify(current.suggestion),
      "It was drawn from these requests, oldest first:",
      ...quote(current.history),
      "They now said, oldest first:",
      ...quote(utterances),
      "Revise the current outline accordingly.",
    );
  } else {
    lines.push("They said, oldest first:", ...quote(utterances), "Draw a new suggestion for this.");
  }

  const response = await parse(
    client,
    {
      model: DRAW_MODEL,
      max_tokens: 16000,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      output_config: { effort: DRAW_EFFORT, format: betaZodOutputFormat(Suggestion) },
      system: DRAW_SYSTEM,
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
    signal,
  );
  if (response.stop_reason === "refusal") return null;
  if (!response.parsed_output) throw new SuggestError(`no outline (stop_reason: ${response.stop_reason})`);
  return sanitize(response.parsed_output, paper);
}

// ---------- the turn ----------

let sharedClient;

// utterances: what they said since the last action (oldest first).
// current: { suggestion, history } for the outline on the page, or null.
export async function decide({ client, imageBase64, mediaType, paper, utterances, current, signal }) {
  client ??= sharedClient ??= new Anthropic();
  const t0 = Date.now();
  const { action, note } = await classify({ client, utterances, current, signal });
  const ms = { filter: Date.now() - t0 };
  if (action === "hide" || action === "ignore") return { action, note, suggestion: null, ms };

  const t1 = Date.now();
  const suggestion = await draw({ client, imageBase64, mediaType, paper, utterances, current, action, signal });
  ms.draw = Date.now() - t1;
  if (!suggestion) return { action: "ignore", note: `${note} (no usable outline)`, suggestion: null, ms };
  return { action, note, suggestion, ms };
}

export class SuggestError extends Error {}

async function parse(client, params, signal) {
  try {
    return await client.beta.messages.parse(params, { signal });
  } catch (err) {
    // Output that doesn't match the schema surfaces as a plain AnthropicError;
    // API failures and aborts are subclasses and propagate to the caller.
    if (err instanceof Anthropic.AnthropicError && !(err instanceof Anthropic.APIError)) {
      throw new SuggestError("malformed model output");
    }
    throw err;
  }
}

// The model is good but not perfect at geometry: clamp to the page and drop
// degenerate strokes. Returns null if nothing drawable is left.
export function sanitize(suggestion, paper) {
  const clampPt = ([x, y]) => [clamp(x, 0, paper.w), clamp(y, 0, paper.h)];
  const strokes = suggestion.strokes
    .map((st) => ({
      ...st,
      points: st.points.filter((p) => p.length >= 2 && p.every(Number.isFinite)).map(clampPt),
    }))
    .filter((st) => st.points.length >= 2);
  return strokes.length ? { ...suggestion, strokes } : null;
}

const quote = (list) => list.map((u) => `- "${u}"`);
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
