// One Meshy image-to-image call, timed and logged.
//   node --env-file=<path to .env> gen.mjs <photo> <model> <out.(png|jpg)> <tag> [aspect] -- <prompt words...>
// Appends a line to eval/imagegen/calls.jsonl: tag, model, aspect, prompt, timings
// (submit, queue, generate, download), credits used. Never prints the key.
import { readFileSync, writeFileSync, appendFileSync } from "node:fs";
import { dirname, join, extname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const sep = argv.indexOf("--");
const [photo, model, out, tag, aspect] = argv.slice(0, sep);
const prompt = argv.slice(sep + 1).join(" ");
const B = "https://api.meshy.ai/openapi/v1/image-to-image";
const H = { Authorization: `Bearer ${process.env.MESHY_API_KEY}`, "content-type": "application/json" };
const mime = extname(photo).toLowerCase() === ".png" ? "image/png" : "image/jpeg";
const uri = `data:${mime};base64,` + readFileSync(photo).toString("base64");

const t0 = Date.now();
const body = { ai_model: model, prompt, reference_image_urls: [uri] };
if (aspect && aspect !== "-") body.aspect_ratio = aspect;
const r = await fetch(B, { method: "POST", headers: H, body: JSON.stringify(body) });
const j = await r.json();
if (!r.ok) { console.log("submit failed", r.status, JSON.stringify(j).slice(0, 300)); process.exit(1); }
const id = j.result;
const tSubmit = Date.now();
let t, tStart = 0;
for (;;) {
  await new Promise((s) => setTimeout(s, 500));
  t = await (await fetch(`${B}/${id}`, { headers: H })).json();
  if (!tStart && t.status === "IN_PROGRESS") tStart = Date.now();
  if (t.status === "SUCCEEDED" || t.status === "FAILED" || t.status === "CANCELED") break;
}
const tDone = Date.now();
let bytes = 0;
if (t.status === "SUCCEEDED") {
  const buf = Buffer.from(await (await fetch(t.image_urls[0])).arrayBuffer());
  bytes = buf.length;
  writeFileSync(out, buf);
}
const tEnd = Date.now();
const rec = {
  at: new Date().toISOString(), tag, model, aspect: aspect || null, status: t.status, prompt,
  photo: photo.split("/").slice(-1)[0], out: out.split("/").slice(-1)[0],
  s: { submit: (tSubmit - t0) / 1000, until_done: (tDone - t0) / 1000, total: (tEnd - t0) / 1000,
       server: t.finished_at && t.created_at ? (t.finished_at - t.created_at) / 1000 : null,
       queued: t.started_at && t.created_at ? (t.started_at - t.created_at) / 1000 : null },
  credits: t.consumed_credits ?? null, bytes, error: t.task_error || null,
};
appendFileSync(join(here, "calls.jsonl"), JSON.stringify(rec) + "\n");
console.log(JSON.stringify({ tag, model, status: t.status, total_s: rec.s.total, server_s: rec.s.server, credits: rec.credits }));
