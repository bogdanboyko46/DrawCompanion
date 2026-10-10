// Claude as the character's art director.
//
// 1. readDrawing: look at the page and write a character sheet: what the
//    figure is, its colors and personality, the prompt for a faithful concept
//    render, how it should be rigged, and which animations suit it.
// 2. reviewConcept: compare the concept render with the drawing. If the render
//    drifted from the design (lost a feature, changed colors, wrong species),
//    return a corrected prompt so the pipeline can retry once before spending
//    credits on 3D.

import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { z } from "zod";

const MODEL = process.env.DRAWCOMPANION_MODEL || "claude-opus-5-5";
// Generation takes minutes anyway; spend a little more thought on getting the
// design right, since every later stage inherits it.
const EFFORT = process.env.DRAWCOMPANION_DIRECTOR_EFFORT || "high";

export const ROLES = ["idle", "walk", "run", "greet", "happy", "dance", "think", "sleep"];

const Sheet = z.object({
  is_character: z
    .boolean()
    .describe("True if the page shows a figure that can stand in AR: a person, animal, creature, robot, or anthropomorphic object."),
  reject_reason: z.string().describe("If not a character, one friendly sentence on why; otherwise empty."),
  name: z.string().describe("The name written on the page, or a short, charming invented one."),
  summary: z.string().describe("One sentence describing the character as drawn."),
  body_plan: z.enum(["humanoid", "biped_creature", "quadruped", "blob", "winged", "object", "other"]),
  riggable: z
    .boolean()
    .describe("True only if it has a humanoid layout (upright, two legs, two arms, a head): the auto-rigger only handles that."),
  height_m: z.number().describe("Plausible real height in meters for this character in its own world, 0.2–3."),
  figure_box: z
    .object({ x: z.number(), y: z.number(), w: z.number(), h: z.number() })
    .describe("Bounding box of the main figure in the image, as fractions 0–1 of width/height, origin top-left."),
  colors: z
    .array(z.object({ hex: z.string(), part: z.string(), from_drawing: z.boolean() }))
    .describe("3–8 colors by body part. Use the drawing's colors; if it is uncolored, invent a palette that fits and mark from_drawing false."),
  design_details: z
    .array(z.string())
    .describe("Every distinctive feature that must survive into 3D: accessories, markings, number of eyes, tail shape, clothing, held items."),
  concept_prompt: z
    .string()
    .describe("Image-to-image prompt (≤700 chars) that turns the drawing into a faithful 3D character render. See the system prompt."),
  texture_prompt: z.string().describe("≤500 chars: surface materials and colors for the 3D texturing pass."),
  personality: z.object({
    traits: z.array(z.string()).describe("2–4 adjectives"),
    energy: z.number().describe("0 calm … 1 hyper; drives walk speed and how often it moves"),
    friendliness: z.number().describe("0 shy … 1 outgoing; drives how it reacts to being approached"),
  }),
  greeting: z.string().describe("A first line the character says when it appears, ≤60 chars, in its voice."),
  animations: z
    .array(z.object({ role: z.enum(ROLES), action_id: z.number().int() }))
    .describe("For riggable characters: pick from the animation library by id. Include idle, greet and happy; add up to two more that suit the personality. walk and run come free with the rig; omit them."),
});

const Review = z.object({
  faithful: z.boolean().describe("True if the render is recognizably the same character design."),
  issues: z.array(z.string()).describe("Concrete differences that matter, most important first."),
  revised_prompt: z.string().describe("If not faithful, a corrected image-to-image prompt (≤700 chars); else empty."),
});

const SHEET_SYSTEM = `You are the art director of DrawCompanion, an AR app that turns a figure drawn on paper into a living 3D character standing on the user's desk.
You see a perspective-corrected photo of the page. Your sheet drives an image model, a 3D generator, an auto-rigger and an animation library, so be precise.

The concept_prompt is the most important field. An image model receives it together with the drawing and must produce a single, clean, full-color render of THIS character that a 3D generator can lift:
- Preserve the design exactly: silhouette, proportions (big head stays big), facial features, number and shape of limbs, every item in design_details, and the colors. Do not "improve" or realistify the design; keep its charm and style. A child's drawing becomes a polished toy-like version of that same drawing, not a different creature.
- Render as a high-quality stylized 3D character (soft studio lighting, clean materials, subtle subsurface), full body, entire figure in frame, facing the viewer, centered, on a plain white background, no ground shadow, no text, no props unless the character holds them.
- For riggable characters: standing in a relaxed T-pose, arms out, legs slightly apart, hands open, nothing covering the body. For others: a neutral standing pose with the limbs clearly separated.
- Mention the medium of the drawing only to say what to keep (e.g. "keep the bold marker outlines as dark seams").

Animations: you get the library as "id: name [category]" lines. Choose clips that match the personality: a shy character gets a timid wave, an energetic one a big jump. Only use ids from the list. If the list is empty, return an empty array.

If the page has no character (a landscape, text, abstract shapes), set is_character false, explain kindly, and fill the other fields minimally.`;

const REVIEW_SYSTEM = `You check concept renders for DrawCompanion. Image 1 is the user's drawing; image 2 is a render meant to be the same character as a clean 3D figure.
Judge fidelity to the DESIGN, not drawing skill: same species/type, same proportions, same features and accessories, same colors (or the planned palette if the drawing was uncolored), full body visible, plain background, usable pose for 3D.
Minor stylization is expected and fine. Flag only differences the user would notice and mind ("it lost the scarf", "it has two eyes instead of three", "cropped feet").`;

let client;

export async function readDrawing({ imageBase64, mediaType, hint, library }) {
  client ??= new Anthropic();
  const libraryText = library?.length
    ? library.map((a) => `${a.id}: ${a.name}${a.category ? ` [${a.category}]` : ""}`).join("\n")
    : "(library unavailable)";
  const text = [
    hint ? `The user says: "${hint}"` : "The user gave no description; read the drawing.",
    "Animation library:",
    libraryText,
  ].join("\n");
  const sheet = await parse(SHEET_SYSTEM, [image(mediaType, imageBase64), { type: "text", text }], Sheet);
  return sanitizeSheet(sheet, library);
}

export async function reviewConcept({ drawing, concept, sheet }) {
  client ??= new Anthropic();
  const text = `Character: ${sheet.name}: ${sheet.summary}\nMust keep: ${sheet.design_details.join("; ")}\nPlanned colors: ${sheet.colors.map((c) => `${c.part} ${c.hex}`).join(", ")}\nPrompt used: ${sheet.concept_prompt}`;
  return parse(
    REVIEW_SYSTEM,
    [image(drawing.mediaType, drawing.base64), image(concept.mediaType, concept.base64), { type: "text", text }],
    Review,
  );
}

async function parse(system, content, schema) {
  let response;
  try {
    response = await client.beta.messages.parse({
      model: MODEL,
      max_tokens: 16000,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      output_config: { effort: EFFORT, format: betaZodOutputFormat(schema) },
      system,
      messages: [{ role: "user", content }],
    });
  } catch (err) {
    if (err instanceof Anthropic.AnthropicError && !(err instanceof Anthropic.APIError)) {
      throw new DirectorError("The character sheet came back malformed. Please try again.");
    }
    throw err;
  }
  if (response.stop_reason === "refusal") throw new DirectorError("This drawing can't be turned into a character.");
  if (!response.parsed_output) throw new DirectorError(`No usable answer (stop_reason: ${response.stop_reason}).`);
  return response.parsed_output;
}

export class DirectorError extends Error {}

const image = (mediaType, data) => ({ type: "image", source: { type: "base64", media_type: mediaType, data } });

// Keep the downstream APIs inside their limits whatever the model wrote.
export function sanitizeSheet(sheet, library = []) {
  const known = new Set(library.map((a) => a.id));
  const seen = new Set();
  const animations = (sheet.animations ?? []).filter((a) => {
    if (a.role === "walk" || a.role === "run") return false; // free with the rig
    if (known.size && !known.has(a.action_id)) return false;
    if (seen.has(a.role)) return false;
    seen.add(a.role);
    return true;
  });
  if (sheet.riggable && !seen.has("idle")) animations.unshift({ role: "idle", action_id: 0 }); // 0 is Meshy's Idle
  const box = sheet.figure_box ?? { x: 0, y: 0, w: 1, h: 1 };
  const bx = clamp(box.x, 0, 1);
  const by = clamp(box.y, 0, 1);
  return {
    ...sheet,
    name: sheet.name.trim().slice(0, 40) || "Doodle",
    greeting: sheet.greeting.slice(0, 80),
    height_m: clamp(sheet.height_m || 1, 0.2, 3),
    figure_box: { x: bx, y: by, w: clamp(box.w, 0.05, 1 - bx), h: clamp(box.h, 0.05, 1 - by) },
    colors: sheet.colors.filter((c) => /^#[0-9a-f]{6}$/i.test(c.hex)).slice(0, 8),
    concept_prompt: sheet.concept_prompt.slice(0, 800),
    texture_prompt: sheet.texture_prompt.slice(0, 800),
    personality: {
      traits: sheet.personality.traits.slice(0, 4),
      energy: clamp(sheet.personality.energy, 0, 1),
      friendliness: clamp(sheet.personality.friendliness, 0, 1),
    },
    animations: animations.slice(0, 5),
  };
}

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, Number.isFinite(v) ? v : lo));
