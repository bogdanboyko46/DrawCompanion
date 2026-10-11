import fs from "node:fs";
process.loadEnvFile("/Users/brandonj/DrawCompanion/.env");
const R = "/Users/brandonj/DrawCompanion-AR";
const Anthropic = (await import(`${R}/node_modules/@anthropic-ai/sdk/index.mjs`)).default;
const { betaZodOutputFormat } = await import(`${R}/node_modules/@anthropic-ai/sdk/helpers/beta/zod.mjs`);
const { flattenPath } = await import(`${R}/server/path.js`);
const src = fs.readFileSync(`${R}/server/suggest.js`, "utf8");
const DRAW_SYSTEM = eval(src.match(/const DRAW_SYSTEM = (`[\s\S]*?`);/)[1]);
const { z } = await import(`${R}/node_modules/zod/index.js`);
const Box = z.object({ x0: z.number(), y0: z.number(), x1: z.number(), y1: z.number() });
const Drawing = z.object({ parts: z.array(z.object({ name: z.string(), box: Box })).describe("First, each existing part of their drawing near where you will draw, with its bounding box in page coordinates read off the grid"), place: z.object({ reason: z.string(), box: Box }).describe("Then where the new piece goes and why, checked against the parts so it does not overlap existing lines unless asked"), strokes: z.array(z.object({ role: z.enum(["construction","contour","detail","shading"]), weight: z.enum(["light","medium","bold"]), d: z.string() })) });
const client = new Anthropic();
const [variant, effort, request, out] = process.argv.slice(2);
const img = fs.readFileSync(variant === "zoom" ? `${process.env.S}/exp/${process.env.Z || "zoom.jpg"}` : `${process.env.S}/last-page3.jpg`).toString("base64");
const lines = ["Page size: 1000 x 444 paper units."];
if (variant === "zoom") lines.push("Image 1 is the whole page. Image 2 is a close-up of the region x 180-680, y 0-360, enlarged so you can see the drawing clearly. Grid labels in both are page coordinates; read positions from the close-up when drawing inside it.");
lines.push("They said, oldest first:", `- "${request}"`, "Draw a new suggestion for this.");
const t0 = Date.now();
let first = null;
const stream = client.beta.messages.stream({
  model: process.env.M || "claude-sonnet-5-5", max_tokens: 16000, output_config: { effort, format: betaZodOutputFormat(Drawing) },
  system: DRAW_SYSTEM,
  messages: [{ role: "user", content: [{ type: "image", source: { type: "base64", media_type: "image/jpeg", data: fs.readFileSync(`${process.env.S}/last-page3.jpg`).toString("base64") } }, { type: "image", source: { type: "base64", media_type: "image/jpeg", data: img } }, { type: "text", text: lines.join("\n") }] }],
});
stream.on("text", () => { first ??= Date.now() - t0; });
const msg = await stream.finalMessage();
const text = msg.content.find((b) => b.type === "text")?.text ?? "{}";
const strokes = JSON.parse(text).strokes.flatMap((s) => flattenPath(s.d, { w: 1000, h: 444 }).map((f) => ({ role: s.role, ...f })));
fs.writeFileSync(out, JSON.stringify(strokes));
const j = JSON.parse(text); console.error(JSON.stringify({ parts: j.parts, place: j.place }));
console.log(`${variant}/${effort} "${request}": first text ${first}ms, total ${Date.now() - t0}ms, out ${msg.usage.output_tokens} tok | ${JSON.parse(text).strokes.map((s) => s.d).join(" | ").slice(0, 300)}`);
