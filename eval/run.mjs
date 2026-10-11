// Placement + latency eval for DrawCompanion's AI, on real page photos.
//
//   node eval/run.mjs draw   [options]   placement and speed of the drawing call (19 cases)
//   node eval/run.mjs filter [options]   new/revise/hide/ignore accuracy of the filter (30 cases)
//
// Options (defaults = what the iPhone app does):
//   --model sonnet|opus|haiku|<id>   drawing model             (sonnet = claude-sonnet-5-5)
//   --effort low|medium|high         drawing effort            (low)
//   --thinking adaptive|between_tools                          (adaptive = the API default)
//   --closeup 900-50-0.4|none        close-up: width-step-margin, made by eval/prep.py
//   --prompts <file>                 Swift file to take the prompts from (ios/.../Prompts.swift);
//                                    e.g. an older version: git show ar/ai:ios/.../Prompts.swift > /tmp/old.swift
//   --cache                          cache_control on the system prompt
//   --only id1,id2                   run some cases
//   --repeat N                       run each case N times (placement varies run to run)
//   --spec-cost                      filter mode: measure what a cancelled speculative drawing call costs
//   --label name                     results file name (default: built from the options)
//
// Every drawing case also runs the filter at the same moment, as the app's
// speculative mode does, so one run gives both latencies:
//   sequential  = filter time + time to first stroke   (the app before speculation)
//   parallel    = max(filter time, time to first stroke) (speculation, when the guess is right)
// Results: eval/results/<label>.json and a table on stdout; `python3 eval/render.py <label>`
// draws each outline onto its photo. Spend is tracked in eval/results/spend.json and the
// eval refuses to start past $4.50 total.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Anthropic from "@anthropic-ai/sdk";
import { flattenPath, StrokeScanner } from "../server/path.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, "..");
const SPEND_FILE = path.join(here, "results", "spend.json");
const SPEND_LIMIT = 4.5;
const PRICES = { // $ per million tokens: input, output
  "claude-sonnet-5-5": [2, 10], "claude-opus-5-5": [4, 20], "claude-haiku-5-5": [0.1, 0.5],
};
const MODELS = { sonnet: "claude-sonnet-5-5", opus: "claude-opus-5-5", haiku: "claude-haiku-5-5" };

// ---------- options ----------

const [mode = "draw", ...rest] = process.argv.slice(2);
const opt = { model: "sonnet", effort: "low", thinking: "adaptive", closeup: "900-50-0.4", prompts: path.join(root, "ios/DrawCompanionAR/Core/Prompts.swift"), repeat: 1 };
for (let i = 0; i < rest.length; i++) {
  const key = rest[i].replace(/^--/, "");
  if (["cache", "spec-cost"].includes(key)) opt[key] = true;
  else opt[key] = rest[++i];
}
opt.repeat = Number(opt.repeat);
const drawModel = MODELS[opt.model] ?? opt.model;
const label = opt.label ?? (mode === "filter" ? `filter${opt.prompts.includes("Prompts.swift") ? "" : "-" + path.basename(opt.prompts, ".swift")}`
  : [opt.model, opt.effort, opt.thinking === "adaptive" ? null : opt.thinking, `closeup-${opt.closeup}`, opt.cache ? "cache" : null,
     opt.prompts.endsWith("Core/Prompts.swift") ? null : path.basename(opt.prompts, ".swift")].filter(Boolean).join("_"));

const cases = JSON.parse(fs.readFileSync(path.join(here, "cases.json"), "utf8"));
const P = loadPrompts(opt.prompts);

if (!process.env.ANTHROPIC_API_KEY && !process.env.ANTHROPIC_AUTH_TOKEN) {
  console.error("No ANTHROPIC_API_KEY: set one to run the eval (see eval/README.md).");
  process.exit(2);
}
const client = new Anthropic({ maxRetries: 2 });

// ---------- prompts: read from the app's Swift source so the eval tests what ships ----------

function loadPrompts(file) {
  const src = fs.readFileSync(file, "utf8");
  const block = (name) => {
    const m = src.match(new RegExp(`static let ${name} = """\\n([\\s\\S]*?)\\n\\s*"""`));
    if (!m) throw new Error(`${name} not found in ${file}`);
    return m[1].split("\n").map((l) => l.replace(/^ {4}/, "")).join("\n");
  };
  // The schemas mirror Prompts.swift (filterSchema, drawSchema); keep them in sync.
  const box = { type: "object", properties: { x0: { type: "number" }, y0: { type: "number" }, x1: { type: "number" }, y1: { type: "number" } }, required: ["x0", "y0", "x1", "y1"], additionalProperties: false };
  const partsFirst = src.includes('"parts"');
  const stroke = {
    type: "object",
    properties: {
      role: { type: "string", enum: ["construction", "contour", "detail", "shading"], description: "construction = proportion/perspective guides (circles, boxes, center lines); contour = main silhouette; detail = interior lines; shading = hatching hints" },
      weight: { type: "string", enum: ["light", "medium", "bold"] },
      d: { type: "string", description: "One continuous line as SVG path data, absolute commands only: M x y, L x y, Q cx cy x y, C c1x c1y c2x c2y x y, Z to close. Integers in paper units. Use curves (Q/C) rather than many short L segments." },
    },
    required: ["role", "weight", "d"], additionalProperties: false,
  };
  const description = (key) => src.match(new RegExp(`"${key}": \\[[\\s\\S]*?"description": "([^"]*)"`))?.[1] ?? "";
  const drawSchema = partsFirst
    ? {
        type: "object",
        properties: {
          parts: { type: "array", description: description("parts"), items: { type: "object", properties: { name: { type: "string" }, box }, required: ["name", "box"], additionalProperties: false } },
          place: { type: "object", description: description("place"), properties: { reason: { type: "string" }, box }, required: ["reason", "box"], additionalProperties: false },
          strokes: { type: "array", items: stroke },
        },
        required: ["parts", "place", "strokes"], additionalProperties: false,
      }
    : { type: "object", properties: { strokes: { type: "array", items: stroke } }, required: ["strokes"], additionalProperties: false };
  const filterSchema = {
    type: "object",
    properties: {
      action: { type: "string", enum: ["new", "revise", "hide", "ignore"], description: "new = draw something new (replaces any current outline); revise = change the current outline; hide = clear the current outline; ignore = not a request to the assistant" },
      note: { type: "string", description: "A few words for the developer log on why. Never shown to the user." },
    },
    required: ["action", "note"], additionalProperties: false,
  };
  return { filterSystem: block("filterSystem"), drawSystem: block("drawSystem"), drawSchema, filterSchema };
}

// server/path.js gives points as [x, y]; the scoring uses {x, y}.
const flatten = (d, paper) => flattenPath(d, paper).map((f) => ({ ...f, points: f.points.map(([x, y]) => ({ x, y })) }));

const quoted = (lines) => lines.map((l) => `- "${l}"`);

// Same text as Prompts.filterText / Prompts.drawText.
function filterText(said, history) {
  const lines = history ? ["An outline is currently shown. It was drawn from these requests, oldest first:", ...quoted(history)] : ["No outline is currently shown."];
  return [...lines, "They just said, oldest first:", ...quoted(said)].join("\n");
}

function drawText(paper, said, current, history, region) {
  const lines = [`Page size: ${paper.w} x ${paper.h} paper units.`];
  if (region) {
    const r = (v) => Math.trunc(v);
    lines.push(`Image 1 is the whole page. Image 2 is a close-up of the region x ${r(region.x)}-${r(region.x + region.w)}, y ${r(region.y)}-${r(region.y + region.h)}, enlarged so you can see the drawing clearly. Grid labels in both are page coordinates; read positions from the close-up when drawing inside it.`);
  }
  if (current) {
    const json = JSON.stringify({ strokes: current.map(({ d, role, weight }) => ({ d, role, weight })) });
    lines.push("Outline currently shown:", json, "It was drawn from these requests, oldest first:", ...quoted(history), "They now said, oldest first:", ...quoted(said), "Revise the current outline accordingly.");
  } else {
    lines.push("They said, oldest first:", ...quoted(said), "Draw a new suggestion for this.");
  }
  return lines.join("\n");
}

// Same words as Speculation.guess in TurnBackend.swift.
function speculate(said, hasOutline) {
  const text = said.join(" ").toLowerCase();
  const words = new Set(text.split(/[^a-z]+/).filter(Boolean));
  const any = (list) => list.some((w) => words.has(w));
  if (!any(["add", "draw", "put", "make", "give", "show", "sketch", "stuck", "suggest", "need", "want", "bigger", "smaller", "larger", "move", "instead", "turn", "change", "another", "more"])) return null;
  if (any(["clear", "hide", "remove", "erase"]) || text.includes("never mind") || text.includes("got it")) return null;
  if (!hasOutline) return "new";
  const adding = any(["add", "draw", "put", "give", "another"]);
  return adding || !any(["bigger", "smaller", "larger", "move", "instead", "turn", "rounder", "thinner", "thicker", "wider", "taller", "shorter", "left", "right", "up", "down", "higher", "lower", "rotate", "flip", "it"]) ? "new" : "revise";
}

// ---------- spend ----------

function cost(model, usage) {
  const [i, o] = PRICES[model] ?? PRICES["claude-opus-5-5"];
  const input = (usage.input_tokens ?? 0) + 1.25 * (usage.cache_creation_input_tokens ?? 0) + 0.1 * (usage.cache_read_input_tokens ?? 0);
  return (input * i + (usage.output_tokens ?? 0) * o) / 1e6;
}
const spent = () => (fs.existsSync(SPEND_FILE) ? JSON.parse(fs.readFileSync(SPEND_FILE, "utf8")).total : 0);
function addSpend(dollars) {
  if (/localhost|127\.0\.0\.1/.test(process.env.ANTHROPIC_BASE_URL ?? "")) return; // eval/mock-api.mjs costs nothing
  fs.mkdirSync(path.dirname(SPEND_FILE), { recursive: true });
  fs.writeFileSync(SPEND_FILE, JSON.stringify({ total: spent() + dollars }));
}
function checkBudget() {
  if (spent() > SPEND_LIMIT) {
    console.error(`Spend so far $${spent().toFixed(2)} is past the $${SPEND_LIMIT} limit; stopping. (eval/results/spend.json)`);
    process.exit(3);
  }
}

// ---------- the two calls ----------

async function classify(said, history, signal) {
  const t0 = performance.now();
  const msg = await client.messages.create({
    model: MODELS.haiku, max_tokens: 2000,
    output_config: { effort: "low", format: { type: "json_schema", schema: P.filterSchema } },
    system: P.filterSystem,
    messages: [{ role: "user", content: filterText(said, history) }],
  }, { signal });
  const ms = performance.now() - t0;
  addSpend(cost(MODELS.haiku, msg.usage));
  let action = "ignore", note = "";
  try { ({ action, note } = JSON.parse(msg.content.find((b) => b.type === "text")?.text ?? "{}")); } catch {}
  if (!history && action === "revise") action = "new";
  if (!history && action === "hide") action = "ignore";
  return { action, note, ms, usage: msg.usage };
}

function images(c, page) {
  const img = (file) => ({ type: "image", source: { type: "base64", media_type: "image/jpeg", data: fs.readFileSync(file).toString("base64") } });
  const full = img(path.join(here, page.photo));
  if (opt.closeup === "none") return { content: [full], region: null };
  const file = `${c.page}-closeup-${opt.closeup}.jpg`;
  const closeupPath = path.join(here, "out", file);
  const regions = JSON.parse(fs.readFileSync(path.join(here, "out", "regions.json"), "utf8"));
  if (!fs.existsSync(closeupPath) || !regions[file]) throw new Error(`missing ${file}: run python3 eval/prep.py ${opt.closeup.split("-").join(" ")}`);
  return { content: [full, img(closeupPath)], region: regions[file] };
}

async function draw(c, page, { signal, onText } = {}) {
  const { content, region } = images(c, page);
  const text = drawText(page.paper, c.said, c.current, c.history, region);
  const params = {
    model: drawModel, max_tokens: 16000,
    output_config: { effort: opt.effort, format: { type: "json_schema", schema: P.drawSchema } },
    system: opt.cache ? [{ type: "text", text: P.drawSystem, cache_control: { type: "ephemeral" } }] : P.drawSystem,
    messages: [{ role: "user", content: [...content, { type: "text", text }] }],
  };
  if (opt.thinking !== "adaptive") params.thinking = { type: opt.thinking };
  if (drawModel !== MODELS.haiku) Object.assign(params, { betas: ["server-side-fallback-2026-07-01"], fallbacks: "default" });

  const t0 = performance.now();
  const ms = { firstText: null, firstStroke: null, total: null };
  const stream = client.beta.messages.stream(params, { signal });
  let scanner = new StrokeScanner();
  const strokes = [];
  let raw = "";
  for await (const event of stream) {
    if (event.type === "content_block_start" && event.content_block.type === "text") scanner = new StrokeScanner();
    if (event.type === "content_block_delta" && event.delta.type === "text_delta") {
      ms.firstText ??= performance.now() - t0;
      raw += event.delta.text;
      onText?.(event.delta.text);
      for (const json of scanner.push(event.delta.text)) {
        let s;
        try { s = JSON.parse(json); } catch { continue; }
        if (typeof s.d !== "string") continue; // parts and place objects
        for (const f of flatten(s.d, page.paper)) {
          const xs = f.points.map((p) => p.x), ys = f.points.map((p) => p.y);
          if (Math.max(Math.max(...xs) - Math.min(...xs), Math.max(...ys) - Math.min(...ys)) < 2) continue; // invisible
          ms.firstStroke ??= performance.now() - t0;
          strokes.push({ role: s.role, weight: s.weight, ...f });
        }
      }
    }
  }
  let msg;
  try { msg = await stream.finalMessage(); } catch { msg = null; }
  ms.total = performance.now() - t0;
  const usage = msg?.usage ?? {};
  addSpend(cost(drawModel, usage));
  let plan = null;
  try { const j = JSON.parse(raw); plan = { parts: j.parts, place: j.place }; } catch {}
  return { strokes, ms, usage, stop: msg?.stop_reason, plan, region, model: msg?.model };
}

// ---------- scoring ----------

const inside = (p, b) => p.x >= b[0] && p.x <= b[2] && p.y >= b[1] && p.y <= b[3];
const shrink = (b, f) => { const dx = (b[2] - b[0]) * f, dy = (b[3] - b[1]) * f; return [b[0] + dx, b[1] + dy, b[2] - dx, b[3] - dy]; };
const distToBox = (p, b) => Math.hypot(Math.max(b[0] - p.x, 0, p.x - b[2]), Math.max(b[1] - p.y, 0, p.y - b[3]));
function bounds(points) {
  const xs = points.map((p) => p.x), ys = points.map((p) => p.y);
  const b = [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)];
  return { box: b, cx: (b[0] + b[2]) / 2, cy: (b[1] + b[3]) / 2, w: b[2] - b[0], h: b[3] - b[1] };
}
const inkCache = {};
function ink(pageName) {
  if (!inkCache[pageName]) {
    const file = path.join(here, "out", `${pageName}-ink.json`);
    if (!fs.existsSync(file)) throw new Error("missing ink masks: run python3 eval/ink.py");
    inkCache[pageName] = new Set(JSON.parse(fs.readFileSync(file, "utf8")).map(([x, y]) => `${x},${y}`));
  }
  return inkCache[pageName];
}
function nearInk(p, cells, r = 4) {
  for (let x = Math.floor((p.x - r) / 2) * 2; x <= p.x + r; x += 2)
    for (let y = Math.floor((p.y - r) / 2) * 2; y <= p.y + r; y += 2) if (cells.has(`${x},${y}`)) return true;
  return false;
}
// Evenly spaced points along the strokes, so long straight segments count by length.
function resample(strokes, step = 3) {
  const out = [];
  for (const s of strokes) {
    const pts = s.closed ? [...s.points, s.points[0]] : s.points;
    for (let i = 1; i < pts.length; i++) {
      const a = pts[i - 1], b = pts[i], n = Math.max(1, Math.ceil(Math.hypot(b.x - a.x, b.y - a.y) / step));
      for (let k = 0; k < n; k++) out.push({ x: a.x + ((b.x - a.x) * k) / n, y: a.y + ((b.y - a.y) * k) / n });
    }
  }
  return out;
}

function score(c, page, strokes) {
  const main = strokes.filter((s) => s.role !== "construction");
  const use = main.length ? main : strokes;
  const pts = resample(use);
  if (!pts.length) return { pass: false, why: "no strokes" };
  const b = bounds(pts);
  const checks = {};
  if (c.revise) {
    const cur = bounds(resample(c.current.flatMap((s) => flatten(s.d, page.paper))));
    const scale = Math.sqrt(Math.max(1, b.w * b.h) / Math.max(1, cur.w * cur.h));
    const dx = b.cx - cur.cx, dy = b.cy - cur.cy;
    const r = c.revise;
    if (r.minScale) checks.grew = scale >= r.minScale;
    if (r.maxScale) checks.shrank = scale <= r.maxScale;
    if (r.maxShift) checks.stayed = Math.hypot(dx, dy) <= r.maxShift;
    if (r.dx) checks.moved = dx >= r.dx[0] && dx <= r.dx[1];
    if (r.maxDy) checks.level = Math.abs(dy) <= r.maxDy;
    const pass = Object.values(checks).every(Boolean);
    return { pass, scale: +scale.toFixed(2), dx: Math.round(dx), dy: Math.round(dy), checks, why: pass ? "" : Object.keys(checks).filter((k) => !checks[k]).join(",") };
  }
  const center = { x: b.cx, y: b.cy };
  checks.where = c.target.some((t) => inside(center, t));
  const avoidNames = c.avoid === "all" ? Object.keys(page.parts) : c.avoid ?? [];
  const hits = pts.filter((p) => avoidNames.some((n) => inside(p, shrink(page.parts[n], 0.12)))).length / pts.length;
  checks.clear = hits <= 0.15;
  const cells = ink(c.page);
  const onInk = pts.filter((p) => nearInk(p, cells)).length / pts.length;
  checks.offLines = onInk <= (c.touch ? 0.45 : 0.25);
  if (c.touch) checks.touches = Math.min(...pts.map((p) => distToBox(p, page.parts[c.touch]))) <= 12;
  if (c.maxSize) checks.size = Math.max(b.w, b.h) <= c.maxSize;
  checks.inPage = b.box[0] >= 0 && b.box[1] >= 0 && b.box[2] <= page.paper.w && b.box[3] <= page.paper.h;
  const pass = Object.values(checks).every(Boolean);
  return { pass, center: [Math.round(b.cx), Math.round(b.cy)], size: [Math.round(b.w), Math.round(b.h)], onAvoided: +hits.toFixed(2), onInk: +onInk.toFixed(2), checks, why: pass ? "" : Object.keys(checks).filter((k) => !checks[k]).join(",") };
}

// ---------- runs ----------

async function pool(items, n, fn) {
  const out = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: n }, async () => {
    while (next < items.length) { const i = next++; out[i] = await fn(items[i], i); }
  }));
  return out;
}

const median = (xs) => { const s = xs.filter((x) => x != null).sort((a, b) => a - b); return s.length ? s[Math.floor(s.length / 2)] : null; };
const p90 = (xs) => { const s = xs.filter((x) => x != null).sort((a, b) => a - b); return s.length ? s[Math.min(s.length - 1, Math.floor(s.length * 0.9))] : null; };
const sec = (ms) => (ms == null ? "  -  " : (ms / 1000).toFixed(1).padStart(5));

async function runDraw() {
  let list = cases.draw;
  if (opt.only) list = list.filter((c) => opt.only.split(",").includes(c.id));
  const jobs = list.flatMap((c) => Array.from({ length: opt.repeat }, (_, k) => ({ c, k })));
  console.log(`${label}: ${jobs.length} drawing calls on ${drawModel} (spent so far $${spent().toFixed(2)})`);
  const results = await pool(jobs, 3, async ({ c, k }) => {
    checkBudget();
    const page = cases.pages[c.page];
    const current = c.current ? c.current.map((s) => ({ ...s, ...flatten(s.d, page.paper)[0] })) : null;
    try {
      const [filter, d] = await Promise.all([classify(c.said, c.history ?? null), draw({ ...c, current: c.current }, page)]);
      const s = score(c, page, d.strokes);
      const r = {
        id: c.id, run: k, said: c.said, page: c.page, pass: s.pass, why: s.why, score: s,
        filter: { action: filter.action, ms: Math.round(filter.ms) },
        ms: { firstText: Math.round(d.ms.firstText), firstStroke: d.ms.firstStroke && Math.round(d.ms.firstStroke), total: Math.round(d.ms.total) },
        sequential: d.ms.firstStroke && Math.round(filter.ms + d.ms.firstStroke),
        parallel: d.ms.firstStroke && Math.round(Math.max(filter.ms, d.ms.firstStroke)),
        usage: d.usage, cost: +cost(drawModel, d.usage).toFixed(4), stop: d.stop, servedBy: d.model, plan: d.plan,
        strokes: d.strokes.map(({ role, d: pd, closed, points }) => ({ role, d: pd, closed, points })), current,
      };
      console.log(`${r.pass ? "PASS" : "fail"} ${c.id.padEnd(22)} first stroke ${sec(r.ms.firstStroke)}s  e2e seq ${sec(r.sequential)}s par ${sec(r.parallel)}s  ${d.strokes.length} strokes  ${r.why}`);
      return r;
    } catch (err) {
      console.log(`ERR  ${c.id.padEnd(22)} ${err.message}`);
      return { id: c.id, run: k, pass: false, why: `error: ${err.message}`, error: String(err) };
    }
  });
  const ok = results.filter((r) => !r.error);
  const summary = {
    label, model: drawModel, effort: opt.effort, thinking: opt.thinking, closeup: opt.closeup, cache: !!opt.cache, prompts: path.relative(root, opt.prompts),
    pass: `${results.filter((r) => r.pass).length}/${results.length}`,
    passRate: +(results.filter((r) => r.pass).length / results.length).toFixed(2),
    medianFirstStroke: median(ok.map((r) => r.ms.firstStroke)), p90FirstStroke: p90(ok.map((r) => r.ms.firstStroke)),
    medianFilter: median(ok.map((r) => r.filter.ms)),
    medianE2ESequential: median(ok.map((r) => r.sequential)), medianE2EParallel: median(ok.map((r) => r.parallel)),
    medianTotal: median(ok.map((r) => r.ms.total)), medianOutputTokens: median(ok.map((r) => r.usage.output_tokens)),
    costPerDrawing: +(ok.reduce((a, r) => a + r.cost, 0) / Math.max(1, ok.length)).toFixed(4),
    filterAgreed: `${ok.filter((r) => r.filter.action === (r.current ? "revise" : "new")).length}/${ok.length}`,
  };
  fs.mkdirSync(path.join(here, "results"), { recursive: true });
  fs.writeFileSync(path.join(here, "results", `${label}.json`), JSON.stringify({ summary, results }, null, 1));
  console.log("\n" + JSON.stringify(summary, null, 1));
  console.log(`\nTotal eval spend so far: $${spent().toFixed(2)}. Overlays: python3 eval/render.py ${label}`);
}

async function runFilter() {
  console.log(`${label}: ${cases.filter.length} filter cases on ${MODELS.haiku}`);
  const results = await pool(cases.filter, 4, async (c) => {
    checkBudget();
    const guess = speculate(c.said, !!c.history);
    let specCost = null;
    const ctl = new AbortController();
    let chars = 0;
    // What starting the drawing call early costs when the filter then says no:
    // the whole input is billed, plus the output written before the cancel.
    const spec = opt["spec-cost"] && guess && c.expect !== guess
      ? draw({ id: "spec", page: "page-3", said: c.said, current: null }, cases.pages["page-3"], { signal: ctl.signal, onText: (t) => (chars += t.length) }).catch(() => null)
      : null;
    const f = await classify(c.said, c.history);
    if (spec) {
      ctl.abort();
      await spec;
      const input = (await client.messages.countTokens({ model: drawModel, system: P.drawSystem, messages: [{ role: "user", content: [...images({ page: "page-3" }, cases.pages["page-3"]).content, { type: "text", text: drawText(cases.pages["page-3"].paper, c.said, null, null, null) }] }] })).input_tokens;
      const [i, o] = PRICES[drawModel];
      specCost = +((input * i + (chars / 3.5) * o) / 1e6).toFixed(4); // thinking before the cancel isn't visible: a lower bound on output
      addSpend(specCost);
    }
    const r = { said: c.said, history: c.history, expect: c.expect, got: f.action, ok: f.action === c.expect, note: f.note, ms: Math.round(f.ms), speculated: guess, specCost };
    console.log(`${r.ok ? "ok  " : "MISS"} ${r.expect.padEnd(6)} got ${r.got.padEnd(6)} ${String(r.ms).padStart(5)}ms  spec ${guess ?? "-"}  ${JSON.stringify(c.said)}${c.history ? " (shown: " + c.history.join(" / ") + ")" : ""}  ${r.ok ? "" : f.note}`);
    return r;
  });
  const wasted = results.filter((r) => r.speculated && r.speculated !== r.expect);
  const summary = {
    label, prompts: path.relative(root, opt.prompts), accuracy: `${results.filter((r) => r.ok).length}/${results.length}`,
    misses: results.filter((r) => !r.ok).map((r) => `${r.said.join(" ")} -> ${r.got} (want ${r.expect})`),
    medianMs: median(results.map((r) => r.ms)), p90Ms: p90(results.map((r) => r.ms)),
    speculation: {
      startedForRequests: `${results.filter((r) => ["new", "revise"].includes(r.expect) && r.speculated === r.expect).length}/${results.filter((r) => ["new", "revise"].includes(r.expect)).length} requests guessed right`,
      wastedOnNonRequests: `${results.filter((r) => ["ignore", "hide"].includes(r.expect) && r.speculated).length}/${results.filter((r) => ["ignore", "hide"].includes(r.expect)).length} chatter/hide phrases start a call`,
      costPerWastedCall: wasted.some((r) => r.specCost != null) ? median(wasted.map((r) => r.specCost)) : "run with --spec-cost",
    },
  };
  fs.mkdirSync(path.join(here, "results"), { recursive: true });
  fs.writeFileSync(path.join(here, "results", `${label}.json`), JSON.stringify({ summary, results }, null, 1));
  console.log("\n" + JSON.stringify(summary, null, 1));
  console.log(`Total eval spend so far: $${spent().toFixed(2)}`);
}

if (mode === "filter") await runFilter();
else if (mode === "draw") await runDraw();
else { console.error("usage: node eval/run.mjs draw|filter [options]"); process.exit(1); }
