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
import { runTurn, SuggestError } from "./suggest.js";
import { mockTurn } from "./mock.js";

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
// current: { suggestion, history } | null }. The response is streamed as
// newline-delimited JSON events so strokes reach the headset as they're drawn:
//   {"type":"action","action":"new"|"revise"|"hide"|"ignore"}
//   {"type":"stroke","stroke":{role, weight, d, closed, points}}   (new/revise)
//   {"type":"done"}   or   {"type":"error","error":"..."}
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
  const current = Array.isArray(body.current?.suggestion?.strokes)
    ? {
        suggestion: { strokes: body.current.suggestion.strokes.slice(0, 80).map(({ role, weight, d }) => ({ role, weight, d: String(d ?? "").slice(0, 4000) })) },
        history: (body.current.history ?? []).slice(-8).map((u) => String(u).slice(0, 500)),
      }
    : null;

  // The client cancels a turn when the user keeps talking; stop paying for it.
  const abort = new AbortController();
  res.on("close", () => !res.writableEnded && abort.abort());

  res.writeHead(200, { "content-type": "application/x-ndjson", "cache-control": "no-store" });
  const emit = (event) => !res.writableEnded && res.write(JSON.stringify(event) + "\n");
  const args = { mediaType: match[1], imageBase64: match[2], paper: body.paper, utterances: utterances.slice(-6), current, signal: abort.signal, emit };
  const started = Date.now();
  try {
    const result = MOCK ? await mockTurn({ ...args, delayMs: MOCK_DELAY_MS }) : await runTurn(args);
    const { filter, firstStroke, draw } = result.ms ?? {};
    const stages = filter != null ? ` [filter ${filter}ms${draw != null ? `, first line ${firstStroke ?? "-"}ms, all ${draw}ms` : ""}]` : "";
    console.log(`${result.action.padEnd(6)} ${Date.now() - started}ms${stages} "${utterances.join(" / ")}" (${result.note})`);
  } catch (err) {
    if (err instanceof Anthropic.APIUserAbortError || abort.signal.aborted) return res.end(); // superseded
    let message;
    if (err instanceof SuggestError) message = err.message;
    else if (err instanceof Anthropic.RateLimitError) message = "Busy, try again in a moment";
    else if (err instanceof Anthropic.AuthenticationError) message = "Server has no valid Anthropic credentials";
    else if (err instanceof Anthropic.APIError) message = `Model error ${err.status}`;
    else {
      console.error(err);
      message = "Internal error";
    }
    emit({ type: "error", error: message });
  }
  res.end();
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
