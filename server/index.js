// Minimal HTTP server: serves the web client and proxies each spoken turn
// to Claude so the API key never reaches the device.
//
//   npm start          real decisions (needs ANTHROPIC_API_KEY or `ant auth login`)
//   npm run mock       canned decisions, no API calls; for trying the flow

import http from "node:http";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Anthropic from "@anthropic-ai/sdk";
import { decide, SuggestError } from "./suggest.js";
import { mockDecision } from "./mock.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC = path.join(here, "..", "public");
const PORT = Number(process.env.PORT || 8787);
const MOCK = process.env.DRAWCOMPANION_MOCK === "1";
const MOCK_DELAY_MS = Number(process.env.DRAWCOMPANION_MOCK_DELAY_MS || 0); // simulate model latency
const MAX_BODY = 8 * 1024 * 1024;

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".svg": "image/svg+xml",
};

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === "POST" && req.url === "/api/turn") return await handleTurn(req, res);
    if (req.method === "GET") return await serveStatic(req, res);
    send(res, 405, { error: "Method not allowed" });
  } catch (err) {
    console.error(err);
    send(res, 500, { error: "Internal error" });
  }
});

// One turn: { image, paper, utterances: [said since the last action],
// current: { suggestion, history } | null } -> { action, note, suggestion }
async function handleTurn(req, res) {
  let body;
  try {
    body = JSON.parse(await readBody(req));
  } catch {
    return send(res, 400, { error: "Body must be JSON under 8 MB" });
  }
  const match = /^data:(image\/(?:jpeg|png|webp));base64,(.+)$/.exec(body.image ?? "");
  const utterances = Array.isArray(body.utterances) ? body.utterances.map((u) => String(u).slice(0, 500)).filter(Boolean) : [];
  if (!match || !body.paper?.w || !body.paper?.h || !utterances.length) {
    return send(res, 400, { error: "Expected { image: dataURL, paper: {w, h}, utterances: [string], current? }" });
  }
  const current = body.current?.suggestion
    ? { suggestion: body.current.suggestion, history: (body.current.history ?? []).slice(-8).map((u) => String(u).slice(0, 500)) }
    : null;

  // The client cancels a turn when the user keeps talking; stop paying for it.
  const abort = new AbortController();
  res.on("close", () => !res.writableEnded && abort.abort());

  const args = { mediaType: match[1], imageBase64: match[2], paper: body.paper, utterances: utterances.slice(-6), current, signal: abort.signal };
  const started = Date.now();
  try {
    if (MOCK) await sleep(MOCK_DELAY_MS, abort.signal);
    const result = MOCK ? mockDecision(args) : await decide(args);
    console.log(`${result.action.padEnd(6)} ${Date.now() - started}ms "${utterances.join(" / ")}" (${result.note})`);
    send(res, 200, result);
  } catch (err) {
    if (err instanceof Anthropic.APIUserAbortError || abort.signal.aborted) return; // superseded by a newer turn
    if (err instanceof SuggestError) return send(res, 422, { error: err.message });
    if (err instanceof Anthropic.RateLimitError) return send(res, 429, { error: "Busy, try again in a moment" });
    if (err instanceof Anthropic.AuthenticationError) return send(res, 500, { error: "Server has no valid Anthropic credentials" });
    if (err instanceof Anthropic.APIError) return send(res, 502, { error: `Model error ${err.status}` });
    throw err;
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

const sleep = (ms, signal) =>
  new Promise((resolve, reject) => {
    const t = setTimeout(resolve, ms);
    signal.addEventListener("abort", () => {
      clearTimeout(t);
      reject(signal.reason);
    });
  });

function send(res, status, obj) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(obj));
}

server.listen(PORT, () => {
  console.log(`DrawCompanion on http://localhost:${PORT}${MOCK ? " (mock mode)" : ""}`);
});
