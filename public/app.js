// DrawCompanion web client ("magic window" prototype).
//
// Point a phone/tablet camera at your page (a stand works best), tap the four
// corners once, then ask for help. The suggestion is drawn on the live video,
// locked to the paper, and fades stroke by stroke as you trace it.

import { applyHomography, invert3x3, paperToImage, rectifyRGBA, toGray } from "./geometry.js";
import { CompletionTracker } from "./completion.js";

const PAPER_W = 1000; // paper units across; height follows the chosen aspect
const UPLOAD_W = 768; // pixels across for the image sent to the model
const TRACK_W = 200; // pixels across for completion tracking
const TRACK_MS = 400;
const OCCLUDED_HINT_MS = 8000;

const $ = (id) => document.getElementById(id);
const view = $("view");
const ctx = view.getContext("2d");
const grab = document.createElement("canvas");
const grabCtx = grab.getContext("2d", { willReadFrequently: true });
const video = Object.assign(document.createElement("video"), { playsInline: true, muted: true });

const state = {
  mode: "camera", // camera | calibrating | ready | region | waiting | showing
  corners: [],
  H: null, // paper -> video pixels
  Hinv: null,
  paperH: 0,
  region: null, // paper units
  dragStart: null,
  dragNow: null,
  result: null,
  index: 0,
  tracker: null,
  trackState: null,
  baseline: null,
  occludedSince: 0,
  fadeStart: 0,
};

// ---------- camera & render loop ----------

async function startCamera() {
  try {
    video.srcObject = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: "environment", width: { ideal: 1920 }, height: { ideal: 1080 } },
      audio: false,
    });
    await video.play();
  } catch (err) {
    hint(`Camera unavailable: ${err.message}. Use https or localhost and allow camera access.`);
    return;
  }
  view.width = grab.width = video.videoWidth;
  view.height = grab.height = video.videoHeight;
  setMode("calibrating");
  hint(cornerHint());
  requestAnimationFrame(render);
}

function render(now) {
  ctx.drawImage(video, 0, 0, view.width, view.height);
  if (state.mode === "calibrating") drawCorners();
  if (state.H && state.mode !== "calibrating") drawPageEdge();
  if (state.mode === "region" && state.dragStart && state.dragNow) drawDragRect();
  if (state.region && (state.mode === "region" || state.mode === "ready" || state.mode === "waiting")) {
    drawPaperRect(state.region, state.mode === "waiting" ? pulse(now) : 0.9, [8, 6]);
  }
  if (state.mode === "waiting" && !state.region) drawPaperRect(fullPage(), pulse(now), [8, 6]);
  if (state.mode === "showing") drawSuggestion(now);
  requestAnimationFrame(render);
}

// ---------- drawing ----------

const unit = () => view.width / 640;

function drawCorners() {
  ctx.fillStyle = "#19c3ff";
  state.corners.forEach(([x, y], i) => {
    ctx.beginPath();
    ctx.arc(x, y, 8 * unit(), 0, Math.PI * 2);
    ctx.fill();
    ctx.font = `${14 * unit()}px system-ui`;
    ctx.fillText(String(i + 1), x + 10 * unit(), y - 10 * unit());
  });
}

function drawPageEdge() {
  strokePaperPath([[0, 0], [PAPER_W, 0], [PAPER_W, state.paperH], [0, state.paperH]], true, {
    color: "rgb(25 195 255 / 0.35)",
    width: 1.5,
  });
}

function drawDragRect() {
  const [x0, y0] = state.dragStart;
  const [x1, y1] = state.dragNow;
  ctx.setLineDash([6 * unit(), 4 * unit()]);
  ctx.strokeStyle = "#19c3ff";
  ctx.lineWidth = 2 * unit();
  ctx.strokeRect(x0, y0, x1 - x0, y1 - y0);
  ctx.setLineDash([]);
}

function drawPaperRect({ x, y, w, h }, alpha, dash) {
  strokePaperPath([[x, y], [x + w, y], [x + w, y + h], [x, y + h]], true, {
    color: `rgb(25 195 255 / ${alpha})`,
    width: 2,
    dash,
  });
}

const ROLE_STYLE = {
  construction: { width: 1.5, dash: [6, 5], alpha: 0.6 },
  contour: { width: 3, dash: [], alpha: 1 },
  detail: { width: 2, dash: [], alpha: 0.9 },
  shading: { width: 1.5, dash: [2, 4], alpha: 0.7 },
};
const WEIGHT = { light: 0.75, medium: 1, bold: 1.4 };

function drawSuggestion(now) {
  const s = current();
  if (!s) return;
  let fade = 1;
  if (state.fadeStart) {
    fade = Math.max(0, 1 - (now - state.fadeStart) / 900);
    if (fade === 0) return finish("Nice — outline cleared. Ask again whenever you're stuck.");
  }
  s.strokes.forEach((st, i) => {
    const style = ROLE_STYLE[st.role] ?? ROLE_STYLE.contour;
    const prog = state.trackState?.strokes[i];
    // Traced strokes step back so the untraced ones stand out.
    const progressFade = prog?.done ? 0.15 : 1 - 0.5 * (prog?.progress ?? 0);
    const alpha = style.alpha * progressFade * fade;
    const width = style.width * (WEIGHT[st.weight] ?? 1);
    // Dark halo first so the line reads on both light paper and dark ink.
    strokePaperPath(st.points, st.closed, { color: `rgb(0 0 0 / ${alpha * 0.55})`, width: width + 2.5, dash: style.dash });
    strokePaperPath(st.points, st.closed, { color: `rgb(25 195 255 / ${alpha})`, width, dash: style.dash });
  });
}

function strokePaperPath(points, closed, { color, width, dash = [] }) {
  if (!state.H || points.length < 2) return;
  ctx.beginPath();
  points.forEach((p, i) => {
    const [x, y] = applyHomography(state.H, p);
    i ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
  });
  if (closed) ctx.closePath();
  ctx.setLineDash(dash.map((d) => d * unit()));
  ctx.lineJoin = ctx.lineCap = "round";
  ctx.strokeStyle = color;
  ctx.lineWidth = width * unit();
  ctx.stroke();
  ctx.setLineDash([]);
}

const pulse = (now) => 0.35 + 0.35 * Math.sin(now / 250);
const fullPage = () => ({ x: 0, y: 0, w: PAPER_W, h: state.paperH });

// ---------- input on the video ----------

function toCanvas(ev) {
  const r = view.getBoundingClientRect();
  return [((ev.clientX - r.left) / r.width) * view.width, ((ev.clientY - r.top) / r.height) * view.height];
}

view.addEventListener("pointerdown", (ev) => {
  const p = toCanvas(ev);
  if (state.mode === "calibrating") {
    state.corners.push(p);
    if (state.corners.length === 4) setCorners();
    else hint(cornerHint());
  } else if (state.mode === "region") {
    state.dragStart = state.dragNow = p;
    view.setPointerCapture(ev.pointerId);
  }
});
view.addEventListener("pointermove", (ev) => {
  if (state.mode === "region" && state.dragStart) state.dragNow = toCanvas(ev);
});
view.addEventListener("pointerup", () => {
  if (state.mode !== "region" || !state.dragStart) return;
  const [x0, y0] = state.dragStart;
  const [x1, y1] = state.dragNow;
  state.dragStart = state.dragNow = null;
  if (Math.abs(x1 - x0) < 10 || Math.abs(y1 - y0) < 10) return;
  const pts = [[x0, y0], [x1, y0], [x1, y1], [x0, y1]].map((p) => applyHomography(state.Hinv, p));
  const xs = pts.map((p) => clamp(p[0], 0, PAPER_W));
  const ys = pts.map((p) => clamp(p[1], 0, state.paperH));
  const x = Math.min(...xs);
  const y = Math.min(...ys);
  state.region = { x, y, w: Math.max(...xs) - x, h: Math.max(...ys) - y };
  setMode("ready");
  hint("Area marked. Now say or type what you want there.");
});

const CORNER_NAMES = ["top-left", "top-right", "bottom-right", "bottom-left"];
const cornerHint = () => `Tap the page's ${CORNER_NAMES[state.corners.length]} corner (${state.corners.length + 1}/4)`;

function setCorners() {
  state.paperH = Math.round(PAPER_W * Number($("paper").value));
  try {
    state.H = paperToImage(state.corners, PAPER_W, state.paperH);
    state.Hinv = invert3x3(state.H);
  } catch {
    state.corners = [];
    hint("Those corners didn't form a page. " + cornerHint());
    return;
  }
  setMode("ready");
  hint("Locked on. Keep the camera and page still. Ask whenever you're stuck.");
}

// ---------- asking ----------

async function ask() {
  if (!state.H) return;
  const request = $("request").value.trim();
  const mode = document.querySelector('input[name="mode"]:checked').value;
  const frame = grabFrame();
  const uploadH = Math.round(UPLOAD_W * (state.paperH / PAPER_W));
  const image = makeUploadImage(rectifyRGBA(frame, grab.width, grab.height, state.H, PAPER_W, state.paperH, UPLOAD_W, uploadH), UPLOAD_W, uploadH);
  state.baseline = trackingGray(frame);

  setMode("waiting");
  hint("Looking at your drawing…");
  try {
    const res = await fetch("/api/suggest", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ image, request, mode, region: state.region, paper: { w: PAPER_W, h: state.paperH } }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
    if (!data.suggestions?.length) throw new Error("No suggestion came back. Try being more specific.");
    showResult(data);
  } catch (err) {
    setMode("ready");
    hint(`Couldn't get a suggestion: ${err.message}`);
  }
}

// The model places points much more accurately with a labeled grid to read.
function makeUploadImage(rgba, w, h) {
  const c = document.createElement("canvas");
  c.width = w;
  c.height = h;
  const g = c.getContext("2d");
  g.putImageData(new ImageData(rgba, w, h), 0, 0);
  const px = w / PAPER_W;
  g.strokeStyle = "rgb(0 150 255 / 0.25)";
  g.fillStyle = "rgb(0 120 220 / 0.8)";
  g.lineWidth = 1;
  g.font = "11px sans-serif";
  for (let u = 100; u < PAPER_W; u += 100) {
    g.beginPath();
    g.moveTo(u * px, 0);
    g.lineTo(u * px, h);
    g.stroke();
    g.fillText(String(u), u * px + 2, 11);
  }
  for (let v = 100; v < state.paperH; v += 100) {
    g.beginPath();
    g.moveTo(0, v * px);
    g.lineTo(w, v * px);
    g.stroke();
    g.fillText(String(v), 2, v * px - 2);
  }
  return c.toDataURL("image/jpeg", 0.85);
}

function showResult(data) {
  state.result = data;
  state.index = 0;
  $("understood").textContent = data.understood;
  $("result").hidden = false;
  const many = data.suggestions.length > 1;
  $("prev").hidden = $("next").hidden = !many;
  selectSuggestion(0);
  setMode("showing");
  hint(many ? "Three ideas: flip through them, then trace the one you like." : "Trace the outline. It fades as you go.");
}

function selectSuggestion(i) {
  const n = state.result.suggestions.length;
  state.index = (i + n) % n;
  const s = current();
  $("palette").replaceChildren(
    ...s.palette.map(({ hex, use }) => {
      const el = document.createElement("span");
      el.className = "swatch";
      el.innerHTML = `<i style="background:${hex}"></i>`;
      el.append(use);
      return el;
    }),
  );
  $("steps").replaceChildren(...s.steps.map((t) => Object.assign(document.createElement("li"), { textContent: t })));
  state.tracker = new CompletionTracker({
    baseline: state.baseline,
    width: TRACK_W,
    height: trackH(),
    paperW: PAPER_W,
    paperH: state.paperH,
    strokes: s.strokes,
  });
  state.trackState = null;
  state.fadeStart = 0;
}

const current = () => state.result?.suggestions[state.index];

function finish(message) {
  state.result = state.tracker = state.trackState = null;
  state.fadeStart = 0;
  state.region = null;
  $("result").hidden = true;
  $("request").value = "";
  setMode("ready");
  hint(message);
}

// ---------- completion tracking ----------

function grabFrame() {
  grabCtx.drawImage(video, 0, 0, grab.width, grab.height);
  return grabCtx.getImageData(0, 0, grab.width, grab.height).data;
}

const trackH = () => Math.round(TRACK_W * (state.paperH / PAPER_W));

function trackingGray(frame) {
  return toGray(rectifyRGBA(frame, grab.width, grab.height, state.H, PAPER_W, state.paperH, TRACK_W, trackH()));
}

setInterval(() => {
  if (state.mode !== "showing" || !state.tracker || state.fadeStart) return;
  const s = state.tracker.update(trackingGray(grabFrame()));
  state.trackState = s;
  if (s.occluded) {
    state.occludedSince ||= performance.now();
    if (performance.now() - state.occludedSince > OCCLUDED_HINT_MS) {
      hint("Lots changed on the page. If it moved, tap Set corners again.");
    }
  } else {
    state.occludedSince = 0;
  }
  if (s.done) state.fadeStart = performance.now();
}, TRACK_MS);

// ---------- controls ----------

function setMode(mode) {
  state.mode = mode;
  const calibrated = !!state.H;
  $("region").disabled = !calibrated || mode === "waiting";
  $("region").classList.toggle("active", mode === "region");
  $("request").disabled = $("ask").disabled = !calibrated || mode === "waiting";
  $("mic").disabled = !calibrated || mode === "waiting" || !Recognition;
}

function hint(text) {
  $("hint").textContent = text;
}

$("calibrate").onclick = () => {
  if (state.mode === "showing") finish("");
  state.corners = [];
  state.H = state.Hinv = null;
  setMode("calibrating");
  hint(cornerHint());
};

$("region").onclick = () => {
  if (state.mode === "region") return setMode("ready");
  state.region = null;
  setMode("region");
  hint("Drag a box where the suggestion should go.");
};

$("ask").onclick = ask;
$("request").addEventListener("keydown", (e) => e.key === "Enter" && ask());
$("prev").onclick = () => selectSuggestion(state.index - 1);
$("next").onclick = () => selectSuggestion(state.index + 1);
$("dismiss").onclick = () => finish("Outline hidden.");

// Hold-to-talk: speech fills the box and asks as soon as you let go.
const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;
if (Recognition) {
  const rec = new Recognition();
  rec.interimResults = true;
  rec.onresult = (e) => ($("request").value = [...e.results].map((r) => r[0].transcript).join(""));
  rec.onend = () => {
    $("mic").classList.remove("active");
    if ($("request").value.trim()) ask();
  };
  $("mic").addEventListener("pointerdown", () => {
    $("request").value = "";
    $("mic").classList.add("active");
    rec.start();
  });
  $("mic").addEventListener("pointerup", () => rec.stop());
} else {
  $("mic").hidden = true;
}

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

startCamera();
