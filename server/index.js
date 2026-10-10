// Minimal HTTP server: serves the web client, proxies suggestion requests to
// Claude, and runs drawing -> 3D character jobs for the iOS app. API keys
// never reach a device.
//
//   npm start          real suggestions and characters (needs ANTHROPIC_API_KEY
//                      or `ant auth login`; characters also need MESHY_API_KEY
//                      and a Python with Blender's bpy, see README)
//   npm run mock       canned results, no API calls; for app and UI work

import http from "node:http";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Anthropic from "@anthropic-ai/sdk";
import { suggest, SuggestError } from "./suggest.js";
import { mockSuggestion } from "./mock.js";
import { readDrawing, reviewConcept } from "./character/director.js";
import { Meshy } from "./character/meshy.js";
import { MockMeshy, mockDirector, mockPacker } from "./character/mock.js";
import { packer as realPacker } from "./character/packer.js";
import { runCharacterJob } from "./character/pipeline.js";
import { PUBLIC_FILES, Store, publicJob } from "./character/store.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC = path.join(here, "..", "public");
const PORT = Number(process.env.PORT || 8787);
const MOCK = process.env.DRAWCOMPANION_MOCK === "1";
const MAX_BODY = 8 * 1024 * 1024;
const DATA = process.env.DRAWCOMPANION_DATA || path.join(here, "..", "data", "characters");
const MAX_RUNNING = Number(process.env.DRAWCOMPANION_MAX_JOBS || 2);

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".svg": "image/svg+xml",
};

const FILE_TYPES = {
  ".usdz": "model/vnd.usdz+zip",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".json": "application/json",
};

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === "POST" && req.url === "/api/suggest") return await handleSuggest(req, res);
    if (req.url.startsWith("/api/characters")) return await handleCharacters(req, res);
    if (req.method === "GET") return await serveStatic(req, res);
    send(res, 405, { error: "Method not allowed" });
  } catch (err) {
    console.error(err);
    send(res, 500, { error: "Internal error" });
  }
});

async function handleSuggest(req, res) {
  let body;
  try {
    body = JSON.parse(await readBody(req));
  } catch {
    return send(res, 400, { error: "Body must be JSON under 8 MB" });
  }
  const match = /^data:(image\/(?:jpeg|png|webp));base64,(.+)$/.exec(body.image ?? "");
  if (!match || !body.paper?.w || !body.paper?.h) {
    return send(res, 400, { error: "Expected { image: dataURL, paper: {w, h}, request, mode, region? }" });
  }
  const args = {
    mediaType: match[1],
    imageBase64: match[2],
    request: String(body.request ?? "").slice(0, 500),
    mode: ["outline", "scaffold", "options"].includes(body.mode) ? body.mode : "outline",
    region: body.region ?? null,
    paper: body.paper,
  };

  const started = Date.now();
  try {
    const result = MOCK ? mockSuggestion(args) : await suggest(args);
    console.log(`suggest mode=${args.mode} ${Date.now() - started}ms "${args.request}"`);
    send(res, 200, result);
  } catch (err) {
    if (err instanceof SuggestError) return send(res, 422, { error: err.message });
    if (err instanceof Anthropic.RateLimitError) return send(res, 429, { error: "Busy, try again in a moment" });
    if (err instanceof Anthropic.AuthenticationError) return send(res, 500, { error: "Server has no valid Anthropic credentials" });
    if (err instanceof Anthropic.APIError) return send(res, 502, { error: `Model error ${err.status}` });
    throw err;
  }
}

// ---- Characters -------------------------------------------------------------

const store = new Store(DATA);
let deps = null; // built lazily so `npm start` works for suggestions without Meshy
const queue = [];
let running = 0;

function characterDeps() {
  if (deps) return deps;
  deps = MOCK
    ? { meshy: new MockMeshy(), director: mockDirector, packer: mockPacker, store }
    : { meshy: new Meshy(), director: { readDrawing, reviewConcept }, packer: realPacker, store };
  return deps;
}

function enqueue(job) {
  if (!queue.includes(job)) queue.push(job);
  pump();
}

function pump() {
  while (running < MAX_RUNNING && queue.length) {
    const job = queue.shift();
    let d;
    try {
      d = characterDeps();
    } catch (err) {
      job.status = "failed";
      job.error = err.message;
      store.save(job).catch(console.error);
      continue;
    }
    running++;
    const started = Date.now();
    runCharacterJob(job, d)
      .then(() => console.log(`character ${job.id} ${job.status} in ${Math.round((Date.now() - started) / 1000)}s`))
      .finally(() => {
        running--;
        pump();
      });
  }
}

async function handleCharacters(req, res) {
  const parts = new URL(req.url, "http://x").pathname.split("/").filter(Boolean); // api, characters, id?, file?
  const [, , id, file] = parts;

  if (req.method === "POST" && !id) {
    try {
      characterDeps();
    } catch (err) {
      return send(res, 503, { error: err.message });
    }
    let body;
    try {
      body = JSON.parse(await readBody(req));
    } catch {
      return send(res, 400, { error: "Body must be JSON under 8 MB" });
    }
    const match = /^data:image\/jpeg;base64,(.+)$/.exec(body.image ?? "");
    if (!match) return send(res, 400, { error: "Expected { image: JPEG dataURL, hint? }" });
    const job = await store.create({ drawing: Buffer.from(match[1], "base64"), hint: String(body.hint ?? "").slice(0, 300) });
    enqueue(job);
    console.log(`character ${job.id} queued "${job.hint}"`);
    return send(res, 202, publicJob(job));
  }

  if (req.method === "GET" && !id) return send(res, 200, { characters: store.list().map((j) => publicJob(j)) });

  const job = id && store.get(id);
  if (!job) return send(res, 404, { error: "No such character" });

  if (req.method === "POST" && file === "retry") {
    if (job.status !== "failed") return send(res, 409, { error: `Character is ${job.status}` });
    job.status = "queued";
    job.message = "Trying again";
    await store.save(job);
    enqueue(job);
    return send(res, 202, publicJob(job));
  }

  if (req.method !== "GET") return send(res, 405, { error: "Method not allowed" });
  if (!file) return send(res, 200, publicJob(job));
  if (!PUBLIC_FILES.has(file)) return send(res, 404, { error: "Not found" });
  try {
    const data = await store.readFile(job.id, file);
    res.writeHead(200, {
      "content-type": FILE_TYPES[path.extname(file)] ?? "application/octet-stream",
      "content-length": data.length,
      "cache-control": file === "clips.json" ? "no-cache" : "private, max-age=86400",
    });
    res.end(data);
  } catch {
    send(res, 404, { error: "Not ready" });
  }
}

async function serveStatic(req, res) {
  const urlPath = decodeURIComponent(new URL(req.url, "http://x").pathname);
  const file = path.normalize(path.join(PUBLIC, urlPath === "/" ? "index.html" : urlPath));
  if (!file.startsWith(PUBLIC + path.sep)) return send(res, 404, { error: "Not found" });
  try {
    const data = await readFile(file);
    res.writeHead(200, { "content-type": TYPES[path.extname(file)] ?? "application/octet-stream" });
    res.end(data);
  } catch {
    send(res, 404, { error: "Not found" });
  }
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (c) => {
      size += c.length;
      if (size > MAX_BODY) {
        reject(new Error("too large"));
        req.destroy();
      } else chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function send(res, status, obj) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(obj));
}

// Jobs that were mid-flight when the server stopped pick up where they left
// off: their Meshy task ids are saved, so nothing is paid for twice.
for (const job of await store.load()) {
  if (job.status === "running" || job.status === "queued") enqueue(job);
}

server.listen(PORT, async () => {
  console.log(`DrawCompanion on http://localhost:${PORT}${MOCK ? " (mock mode)" : ""}`);
  if (!MOCK) {
    if (!process.env.MESHY_API_KEY) console.warn("MESHY_API_KEY not set: /api/characters is disabled");
    else if (!(await realPacker.available())) {
      console.warn("Blender's bpy is not importable by DRAWCOMPANION_PYTHON: animated characters will fail to package. See README.");
    }
  }
});
