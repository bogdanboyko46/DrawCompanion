// Minimal HTTP server: serves the web client and proxies suggestion requests
// to Claude so the API key never reaches the device.
//
//   npm start          real suggestions (needs ANTHROPIC_API_KEY or `ant auth login`)
//   npm run mock       canned suggestion, no API calls; for UI work

import http from "node:http";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Anthropic from "@anthropic-ai/sdk";
import { suggest, SuggestError } from "./suggest.js";
import { mockSuggestion } from "./mock.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC = path.join(here, "..", "public");
const PORT = Number(process.env.PORT || 8787);
const MOCK = process.env.DRAWCOMPANION_MOCK === "1";
const MAX_BODY = 8 * 1024 * 1024;

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".svg": "image/svg+xml",
};

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === "POST" && req.url === "/api/suggest") return await handleSuggest(req, res);
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
    return send(res, 400, { error: "Expected { image: dataURL, paper: {w, h}, request, mode, region?, revision? }" });
  }
  const args = {
    mediaType: match[1],
    imageBase64: match[2],
    request: String(body.request ?? "").slice(0, 500),
    mode: ["outline", "scaffold", "options"].includes(body.mode) ? body.mode : "outline",
    region: body.region ?? null,
    paper: body.paper,
    revision: parseRevision(body.revision),
  };

  const started = Date.now();
  try {
    const result = MOCK ? mockSuggestion(args) : await suggest(args);
    const what = args.revision ? `revise "${args.revision.feedback.at(-1)}"` : `"${args.request}"`;
    console.log(`suggest mode=${args.mode} ${Date.now() - started}ms ${what}`);
    send(res, 200, result);
  } catch (err) {
    if (err instanceof SuggestError) return send(res, 422, { error: err.message });
    if (err instanceof Anthropic.RateLimitError) return send(res, 429, { error: "Busy, try again in a moment" });
    if (err instanceof Anthropic.AuthenticationError) return send(res, 500, { error: "Server has no valid Anthropic credentials" });
    if (err instanceof Anthropic.APIError) return send(res, 502, { error: `Model error ${err.status}` });
    throw err;
  }
}

function parseRevision(rev) {
  if (!rev?.previous || !Array.isArray(rev.feedback) || !rev.feedback.length) return null;
  return {
    previous: rev.previous,
    feedback: rev.feedback.slice(-5).map((f) => String(f).slice(0, 300)),
  };
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

server.listen(PORT, () => {
  console.log(`DrawCompanion on http://localhost:${PORT}${MOCK ? " (mock mode)" : ""}`);
});
