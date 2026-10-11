// Turns what the user just said + a photo of their page into an action on
// the outline. The microphone is always on and the AI never talks back: it
// only draws, changes, or clears the outline, or ignores speech that isn't
// meant for it. Claude decides where things go; there is no user-placed box.
//
// Two stages, because most of what an always-on microphone hears is chatter:
//   1. filter (Claude Haiku, text only): new | revise | hide | ignore.
//      Fast and nearly free; most phrases stop here.
//   2. draw (Claude Sonnet, with the page photo): only for new / revise.
//      Streams: each stroke is passed on the moment it's complete, so the
//      first lines appear while the rest are still being written.

import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { z } from "zod";
import { flattenPath, StrokeScanner } from "./path.js";

const FILTER_MODEL = process.env.DRAWCOMPANION_FILTER_MODEL || "claude-haiku-5-5";
const DRAW_MODEL = process.env.DRAWCOMPANION_DRAW_MODEL || "claude-sonnet-5-5";
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

- new: they are asking for something to be drawn or suggested ("add a cat on the windowsill", "I'm stuck, what goes here?", "give me something else", "what if there was a tree"). This includes adding to or changing their own drawing when no outline is shown ("add another leg", "give him a hat", "can you add a nose?"): the page always has their drawing on it, so "it", "him" or "the drawing" refer to that.
- revise: an outline is currently shown and they want THAT outline changed ("bigger", "make it face left", "move it up a bit", "no, a pine tree", "make the ears rounder" when the outline is ears). Only possible when an outline is shown.
- An outline being shown doesn't make every request a revision. If they ask for a different thing than the outline is (the outline came from "add an arm" and they now say "can you add teeth to the smile?" or "give him a hat"), that is new. Revise only when the words are about the outline itself: its size, position, direction, style, or replacing it with something else ("no, a pine tree", "make it a dog instead").
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
  weight: z.enum(["light", "medium", "bold"]),
  d: z
    .string()
    .describe(
      "One continuous line as SVG path data, absolute commands only: M x y, L x y, Q cx cy x y, C c1x c1y c2x c2y x y, Z to close. Integers in paper units. Use curves (Q/C) rather than many short L segments.",
    ),
});

const Drawing = z.object({ strokes: z.array(Stroke) });

const DRAW_SYSTEM = `You are DrawCompanion, a silent drawing assistant inside an AR headset.
The user is drawing on real paper and asked (out loud) for help. You never reply in words. Your only output is an outline, as vector strokes, that is projected onto their paper for them to trace. They are waiting, so be quick: decide and draw.

You get a top-down, perspective-corrected photo of their page with a faint labeled coordinate grid (paper units; origin top-left, x right, y down), what they said, and the outline currently shown (if any). The black-and-white squares in the corners and at the middle of the side edges are tracking markers: ignore them and never draw over them.

Choosing where it goes (it's entirely your call):
- Read the drawing: what's there, its perspective, scale, and where the composition has room. Put the suggestion where it makes sense for the scene and the request ("on the windowsill" means on the drawn windowsill). Use empty space; never cover existing work unless they asked to change it.
- Connect to existing lines where natural (a branch starts on the trunk; a hand attaches to the wrist) and match the size of neighboring objects.
- Another copy of an existing part (a third leg, another eye) goes beside the existing ones, same size and attached the same way, never on top of them.
- Something that belongs on or in a named part goes there: teeth inside the smile, a hat on top of the head, buttons on the body. Touch that part, but don't cover its neighbors.

How to draw it:
- Continue THEIR drawing. Match subject matter, scale, perspective, line weight, and level of detail. A loose sketch gets a loose suggestion; a careful study gets careful lines.
- Order matters: strokes appear on the paper one by one as you write them. Write construction strokes first (simple shapes that set size and placement), then contours, then a little detail. Skip shading unless asked. If they ask for just guidelines, write only construction strokes.
- Prefer fewer, confident strokes, each a smooth path built from curves.
- When revising, change what they asked for and keep everything else (placement, size, style) the same.
- Coordinates must be accurate: use the grid labels to place points. Points must stay inside the page.`;

// Streams the drawing; calls onStroke({ role, weight, d, closed, points }) as
// each stroke completes. Returns the number of strokes delivered.
export async function draw({ client, imageBase64, mediaType, paper, utterances, current, action, signal, onStroke }) {
  const lines = [`Page size: ${paper.w} x ${paper.h} paper units.`];
  if (action === "revise") {
    lines.push(
      "Outline currently shown:",
      JSON.stringify({ strokes: current.suggestion.strokes.map(({ role, weight, d }) => ({ role, weight, d })) }),
      "It was drawn from these requests, oldest first:",
      ...quote(current.history),
      "They now said, oldest first:",
      ...quote(utterances),
      "Revise the current outline accordingly.",
    );
  } else {
    lines.push("They said, oldest first:", ...quote(utterances), "Draw a new suggestion for this.");
  }

  const stream = client.beta.messages.stream(
    {
      model: DRAW_MODEL,
      max_tokens: 16000,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      output_config: { effort: DRAW_EFFORT, format: betaZodOutputFormat(Drawing) },
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
    { signal },
  );

  let scanner = new StrokeScanner();
  let delivered = 0;
  let stopReason = null;
  try {
    for await (const event of stream) {
      if (event.type === "content_block_start" && event.content_block.type === "text") {
        scanner = new StrokeScanner(); // a fallback model starts its answer over
      } else if (event.type === "content_block_delta" && event.delta.type === "text_delta") {
        for (const json of scanner.push(event.delta.text)) {
          for (const stroke of toStrokes(json, paper)) {
            onStroke(stroke);
            delivered++;
          }
        }
      } else if (event.type === "message_delta") {
        stopReason = event.delta.stop_reason ?? stopReason;
      }
    }
  } catch (err) {
    // The SDK parses the whole answer at the end; strokes already shown were
    // validated one by one, so a final parse failure only matters if none were.
    const parseFailure = err instanceof Anthropic.AnthropicError && !(err instanceof Anthropic.APIError);
    if (!parseFailure) throw err;
    if (!delivered) throw new SuggestError("malformed model output");
  }
  if (!delivered && stopReason !== "refusal" && stopReason !== "end_turn") {
    throw new SuggestError(`no outline (stop_reason: ${stopReason})`);
  }
  return delivered;
}

// One streamed stroke object -> drawable strokes (a path with several M
// commands becomes several strokes). Malformed strokes are dropped.
export function toStrokes(json, paper) {
  let raw;
  try {
    raw = JSON.parse(json);
  } catch {
    return [];
  }
  const role = ["construction", "contour", "detail", "shading"].includes(raw.role) ? raw.role : "contour";
  const weight = ["light", "medium", "bold"].includes(raw.weight) ? raw.weight : "medium";
  return flattenPath(raw.d ?? "", paper).map((s) => ({ role, weight, ...s }));
}

// ---------- the turn ----------

let sharedClient;

// utterances: what they said since the last action (oldest first).
// current: { suggestion, history } for the outline on the page, or null.
// emit receives, in order: { type: "action", action }, then for new/revise
// { type: "stroke", stroke } per stroke, then { type: "done" }.
export async function runTurn({ client, imageBase64, mediaType, paper, utterances, current, signal, emit }) {
  client ??= sharedClient ??= new Anthropic();
  const t0 = Date.now();
  const { action, note } = await classify({ client, utterances, current, signal });
  const ms = { filter: Date.now() - t0 };
  emit({ type: "action", action });
  if (action === "hide" || action === "ignore") {
    emit({ type: "done" });
    return { action, note, ms };
  }

  const t1 = Date.now();
  const count = await draw({
    client, imageBase64, mediaType, paper, utterances, current, action, signal,
    onStroke: (stroke) => {
      ms.firstStroke ??= Date.now() - t1;
      emit({ type: "stroke", stroke });
    },
  });
  ms.draw = Date.now() - t1;
  emit({ type: "done" });
  return { action, note: count ? note : `${note} (no usable outline)`, ms, strokes: count };
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

const quote = (list) => list.map((u) => `- "${u}"`);
