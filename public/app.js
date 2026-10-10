// DrawCompanion web client.
//
// Two views of the same pipeline:
//   - Headset: the phone sits in a lightweight viewer. Its camera shows your
//     page to both eyes, with the outline on top. You aim a reticle by moving
//     your head and tap the viewer's button: tap two corners to box where the
//     suggestion goes, then say what you want. Tap again to ask for changes.
//   - Phone: the same thing on a handheld or propped-up phone; drag a box,
//     type or talk.
// The page is found every frame from the printed template's markers, so the
// outline stays on the paper while your head (or the paper) moves.

import { applyHomography, invert3x3, multiply, rectifyRGBA, toGray } from "./geometry.js";
import { CompletionTracker } from "./completion.js";
import { boardLayout } from "./board.js";
import { PaperTracker, pageMotion } from "./tracking.js";

const DETECT_W = 960; // marker detection runs on a downscaled frame
const TRACK_W = 200; // completion tracking grid
const TRACK_MS = 300;
const UPLOAD_W = 768; // image sent to the model
const LOST_MS = 300; // keep the last pose this long when markers drop out
const ZOOM = 1.6; // headset: crop of the camera image shown to each eye

const $ = (id) => document.getElementById(id);
const view = $("view");
const ctx = view.getContext("2d");
const det = document.createElement("canvas");
const detCtx = det.getContext("2d", { willReadFrequently: true });
const video = Object.assign(document.createElement("video"), { playsInline: true, muted: true });
const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;

const state = {
  headset: false,
  step: "idle", // idle | boxing | boxed | listening | waiting | showing
  layout: boardLayout($("paper").value),
  paperTracker: null,
  H: null, // paper -> video pixels, null when the page isn't visible
  lastSeen: 0,
  visible: false,
  detImage: null,
  box: null, // paper units
  boxStart: null, // paper point where the box began
  dragNow: null, // phone: paper point under the finger
  request: "",
  mode: "outline",
  feedback: [],
  result: null,
  index: 0,
  tracker: null,
  trackState: null,
  trackH: null,
  fadeStart: 0,
  hintText: "",
};

// ---------- camera, tracking, render loop ----------

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
  det.width = DETECT_W;
  det.height = Math.round((DETECT_W * video.videoHeight) / video.videoWidth);
  state.paperTracker = new PaperTracker(new AR.Detector(), state.layout);
  hint("Point the camera at your printed DrawCompanion page.");
  resize();
  requestAnimationFrame(frame);
}

function frame(now) {
  detCtx.drawImage(video, 0, 0, det.width, det.height);
  state.detImage = detCtx.getImageData(0, 0, det.width, det.height);
  const { H } = state.paperTracker.update(state.detImage, video.videoWidth / det.width);
  if (H) {
    state.H = H;
    state.lastSeen = now;
  } else if (now - state.lastSeen > LOST_MS) {
    state.H = null;
  }
  // Say so when the page comes into or drops out of view.
  if (!!state.H !== state.visible) {
    state.visible = !!state.H;
    if (!state.H) hint("Can't see the page. Look at it so the corner squares are in view.");
    else if (state.step === "idle" && !state.result) hint(idleHint());
    else if (state.step === "showing") hint(state.headset ? "Tap to ask for changes." : "Not quite? Say or type what to change.");
  }
  render(now);
  requestAnimationFrame(frame);
}

const idleHint = () =>
  state.headset
    ? "Aim the dot at one corner of where you want help, then tap."
    : "Drag a box where you want help, then say or type what you want.";

// ---------- views ----------

function resize() {
  if (state.headset) {
    view.width = Math.round(innerWidth * devicePixelRatio);
    view.height = Math.round(innerHeight * devicePixelRatio);
  } else {
    view.width = video.videoWidth;
    view.height = video.videoHeight;
  }
}
addEventListener("resize", () => video.videoWidth && resize());

// Each viewport shows a crop of the camera image. Returns {x, y, w, h}
// (canvas rect) and the transform from video pixels into it.
function viewports() {
  const vw = video.videoWidth;
  const vh = video.videoHeight;
  if (!state.headset) return [{ x: 0, y: 0, w: view.width, h: view.height, scale: view.width / vw, cx: 0, cy: 0 }];
  const eyeW = view.width / 2;
  const eyeH = view.height;
  let cropH = vh / ZOOM;
  let cropW = (cropH * eyeW) / eyeH;
  if (cropW > vw) [cropW, cropH] = [vw, (vw * eyeH) / eyeW];
  const cx = (vw - cropW) / 2;
  const cy = (vh - cropH) / 2;
  return [0, 1].map((i) => ({ x: i * eyeW, y: 0, w: eyeW, h: eyeH, scale: eyeW / cropW, cx, cy }));
}

function render(now) {
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.fillStyle = "#000";
  ctx.fillRect(0, 0, view.width, view.height);
  for (const vp of viewports()) {
    ctx.save();
    ctx.beginPath();
    ctx.rect(vp.x, vp.y, vp.w, vp.h);
    ctx.clip();
    ctx.setTransform(vp.scale, 0, 0, vp.scale, vp.x - vp.cx * vp.scale, vp.y - vp.cy * vp.scale);
    ctx.drawImage(video, 0, 0);
    drawScene(now);
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    if (state.headset) drawHud(vp);
    ctx.restore();
  }
}

function drawScene(now) {
  if (!state.H) return;
  const { paperW, paperH } = state.layout;
  strokePaperPath([[0, 0], [paperW, 0], [paperW, paperH], [0, paperH]], true, {
    color: "rgb(25 195 255 / 0.35)",
    width: 1.5,
  });
  const pending = state.step === "boxing" ? reticleOrDrag() : null;
  if (pending) drawBox(rectFrom(state.boxStart, pending), 0.9);
  if (state.box && ["boxed", "listening", "idle"].includes(state.step) && !state.result) drawBox(state.box, 0.9);
  if (state.step === "waiting") drawBox(state.box ?? fullPage(), pulse(now));
  if (state.result && state.step !== "waiting") drawSuggestion(now);
}

const unit = () => video.videoWidth / 640;

function drawBox({ x, y, w, h }, alpha) {
  strokePaperPath([[x, y], [x + w, y], [x + w, y + h], [x, y + h]], true, {
    color: `rgb(25 195 255 / ${alpha})`,
    width: 2,
    dash: [8, 6],
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
  let fade = 1;
  if (state.fadeStart) {
    fade = Math.max(0, 1 - (now - state.fadeStart) / 900);
    if (fade === 0) return finish("Outline cleared. Box a new spot whenever you're stuck.");
  }
  s.strokes.forEach((st, i) => {
    const style = ROLE_STYLE[st.role] ?? ROLE_STYLE.contour;
    const prog = state.trackState?.strokes[i];
    // Traced strokes step back so the untraced ones stand out.
    const progressFade = prog?.done ? 0.3 : 1 - 0.5 * (prog?.progress ?? 0);
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

// Headset overlay in eye coordinates: aiming dot and status text.
function drawHud(vp) {
  const s = vp.h / 400;
  const cx = vp.x + vp.w / 2;
  const cy = vp.y + vp.h / 2;
  ctx.fillStyle = state.H ? "#19c3ff" : "#ff8a3d";
  ctx.strokeStyle = "rgb(0 0 0 / 0.7)";
  ctx.lineWidth = 2 * s;
  ctx.beginPath();
  ctx.arc(cx, cy, 4 * s, 0, Math.PI * 2);
  ctx.fill();
  ctx.stroke();

  ctx.font = `${11 * s}px system-ui, sans-serif`;
  ctx.textAlign = "center";
  const lines = wrap(state.hintText, vp.w * 0.7);
  const lh = 14 * s;
  const top = vp.y + vp.h * 0.88 - (lines.length - 1) * lh;
  ctx.fillStyle = "rgb(0 0 0 / 0.6)";
  ctx.fillRect(cx - vp.w * 0.37, top - lh, vp.w * 0.74, lines.length * lh + 6 * s);
  ctx.fillStyle = "#fff";
  lines.forEach((l, i) => ctx.fillText(l, cx, top + i * lh));
  ctx.textAlign = "start";
}

function wrap(text, maxW) {
  const lines = [];
  let line = "";
  for (const word of text.split(" ")) {
    const next = line ? `${line} ${word}` : word;
    if (ctx.measureText(next).width > maxW && line) {
      lines.push(line);
      line = word;
    } else line = next;
  }
  return line ? [...lines, line] : lines;
}

const pulse = (now) => 0.35 + 0.35 * Math.sin(now / 250);
const fullPage = () => ({ x: 0, y: 0, w: state.layout.paperW, h: state.layout.paperH });

// ---------- pointing ----------

// Paper point at the center of the camera image (where the headset reticle is).
function reticlePaper() {
  if (!state.H) return null;
  return clampPaper(applyHomography(invert3x3(state.H), [video.videoWidth / 2, video.videoHeight / 2]));
}

const reticleOrDrag = () => (state.headset ? reticlePaper() : state.dragNow);

function canvasToPaper(ev) {
  if (!state.H) return null;
  const r = view.getBoundingClientRect();
  const v = [((ev.clientX - r.left) / r.width) * video.videoWidth, ((ev.clientY - r.top) / r.height) * video.videoHeight];
  return clampPaper(applyHomography(invert3x3(state.H), v));
}

const clampPaper = ([x, y]) => [clamp(x, 0, state.layout.paperW), clamp(y, 0, state.layout.paperH)];

function rectFrom([x0, y0], [x1, y1]) {
  return { x: Math.min(x0, x1), y: Math.min(y0, y1), w: Math.abs(x1 - x0), h: Math.abs(y1 - y0) };
}

const MIN_BOX = 30; // paper units (about 6 mm)

function setBox(a, b) {
  const box = rectFrom(a, b);
  state.boxStart = state.dragNow = null;
  if (box.w < MIN_BOX || box.h < MIN_BOX) {
    state.box = null;
    state.step = "idle";
    hint("Box too small, cancelled.");
    return false;
  }
  state.box = box;
  state.step = "boxed";
  return true;
}

// ---------- headset: everything is look + tap (the viewer's button) ----------

function headsetTap() {
  switch (state.step) {
    case "idle": {
      const p = reticlePaper();
      if (!p) return hint("Can't see the page. Look at it so the corner squares are in view.");
      state.boxStart = p;
      state.step = "boxing";
      return hint("Now aim at the opposite corner and tap.");
    }
    case "boxing": {
      const p = reticlePaper();
      if (!p) return hint("Lost the page. Look back at it and tap again.");
      if (setBox(state.boxStart, p)) listen("request");
      return;
    }
    case "boxed":
      return listen("request");
    case "listening":
      return stopListening();
    case "showing":
      return listen("feedback");
  }
}

// ---------- phone: drag a box ----------

view.addEventListener("pointerdown", (ev) => {
  if (state.headset) return headsetTap();
  if (!["idle", "boxed"].includes(state.step) || state.result) return;
  const p = canvasToPaper(ev);
  if (!p) return hint("Point the camera at your printed DrawCompanion page first.");
  state.boxStart = state.dragNow = p;
  state.step = "boxing";
  view.setPointerCapture(ev.pointerId);
});
view.addEventListener("pointermove", (ev) => {
  if (!state.headset && state.step === "boxing") state.dragNow = canvasToPaper(ev) ?? state.dragNow;
});
view.addEventListener("pointerup", () => {
  if (state.headset || state.step !== "boxing") return;
  if (setBox(state.boxStart, state.dragNow)) hint("Box set. Now say or type what you want there.");
});

// ---------- voice ----------

let recognition = null;

function listen(kind) {
  if (!Recognition) {
    return hint(state.headset ? "This browser has no speech input; use the phone view." : "Type it in the box below.");
  }
  const before = state.step;
  recognition = new Recognition();
  recognition.interimResults = true;
  let heard = "";
  recognition.onresult = (e) => {
    heard = [...e.results].map((r) => r[0].transcript).join("");
    hint(`“${heard}”`);
    if (!state.headset) $(kind === "request" ? "request" : "feedback").value = heard;
  };
  recognition.onerror = () => {};
  recognition.onend = () => {
    recognition = null;
    $("mic").classList.remove("active");
    state.step = before;
    heard = heard.trim();
    if (!heard) return hint(kind === "request" ? "Didn't catch that. Tap and try again." : "Didn't catch that.");
    kind === "request" ? ask(heard) : handleFeedback(heard);
  };
  state.step = "listening";
  $("mic").classList.add("active");
  hint(kind === "request" ? "Listening… what should go in the box?" : "Listening… what should change?");
  recognition.start();
}

function stopListening() {
  recognition?.stop();
}

function handleFeedback(text) {
  if (/^(hide|clear|remove|done|cancel|stop|never ?mind)\b/i.test(text)) return finish("Outline hidden.");
  if (state.result.suggestions.length > 1) {
    if (/^(next|another)\b/i.test(text)) return selectSuggestion(state.index + 1);
    if (/^(previous|back)\b/i.test(text)) return selectSuggestion(state.index - 1);
  }
  revise(text);
}

// "Give me ideas…" and "just the guides…" pick the mode by voice.
function modeFor(text) {
  if (/\b(ideas|options)\b/i.test(text)) return "options";
  if (/\b(guides?|guidelines|construction)\b/i.test(text)) return "scaffold";
  return document.querySelector('input[name="mode"]:checked').value;
}

// ---------- asking and revising ----------

async function ask(request) {
  state.request = request;
  state.feedback = [];
  state.mode = modeFor(request);
  await requestSuggestion({ request, mode: state.mode });
}

async function revise(feedback) {
  state.feedback.push(feedback);
  await requestSuggestion({
    request: state.request,
    mode: state.mode,
    revision: { previous: current(), feedback: state.feedback },
  });
}

async function requestSuggestion(body) {
  if (!state.H) return hint("Can't see the page right now. Look at it and try again.");
  const { image, baseline } = capturePage();
  const previous = state.result;
  state.step = "waiting";
  hint(body.revision ? "Changing it…" : "Looking at your drawing…");
  try {
    const res = await fetch("/api/suggest", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        ...body,
        image,
        region: state.box,
        paper: { w: state.layout.paperW, h: state.layout.paperH },
      }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
    if (!data.suggestions?.length) throw new Error("no suggestion came back, try being more specific");
    state.baseline = baseline;
    showResult(data);
  } catch (err) {
    if (body.revision) state.feedback.pop();
    state.result = previous;
    state.step = previous ? "showing" : state.box ? "boxed" : "idle";
    hint(`Couldn't get a suggestion: ${err.message}`);
  }
}

// Top-down image of the page for the model (with a labeled grid, which makes
// its coordinates much more accurate) and a small grayscale baseline for
// completion tracking, both from the same moment.
function capturePage() {
  const { paperW, paperH } = state.layout;
  const full = document.createElement("canvas");
  full.width = video.videoWidth;
  full.height = video.videoHeight;
  const fctx = full.getContext("2d");
  fctx.drawImage(video, 0, 0);
  const pixels = fctx.getImageData(0, 0, full.width, full.height).data;
  const upH = Math.round((UPLOAD_W * paperH) / paperW);
  const rgba = rectifyRGBA(pixels, full.width, full.height, state.H, paperW, paperH, UPLOAD_W, upH);
  const baseline = toGray(rectifyRGBA(pixels, full.width, full.height, state.H, paperW, paperH, TRACK_W, trackH()));
  return { image: withGrid(rgba, UPLOAD_W, upH), baseline };
}

function withGrid(rgba, w, h) {
  const c = document.createElement("canvas");
  c.width = w;
  c.height = h;
  const g = c.getContext("2d");
  g.putImageData(new ImageData(rgba, w, h), 0, 0);
  const { paperW, paperH } = state.layout;
  const px = w / paperW;
  g.strokeStyle = "rgb(0 150 255 / 0.25)";
  g.fillStyle = "rgb(0 120 220 / 0.8)";
  g.lineWidth = 1;
  g.font = "11px sans-serif";
  for (let u = 100; u < paperW; u += 100) {
    g.beginPath();
    g.moveTo(u * px, 0);
    g.lineTo(u * px, h);
    g.stroke();
    g.fillText(String(u), u * px + 2, 11);
  }
  for (let v = 100; v < paperH; v += 100) {
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
  $("understood").textContent = data.understood;
  $("result").hidden = false;
  const many = data.suggestions.length > 1;
  $("prev").hidden = $("next").hidden = !many;
  selectSuggestion(0);
  state.step = "showing";
  const how = state.headset ? "Tap to ask for changes" : "Not quite? Say or type what to change";
  hint(many ? `Three ideas. Say “next” to flip, or describe a change.` : `Trace it. ${how}. It clears 3 s after you stop.`);
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
    paperW: state.layout.paperW,
    paperH: state.layout.paperH,
    strokes: s.strokes,
    now: performance.now(),
  });
  state.trackState = null;
  state.fadeStart = 0;
}

const current = () => state.result?.suggestions[state.index];

function finish(message) {
  stopListening();
  Object.assign(state, { result: null, tracker: null, trackState: null, fadeStart: 0, box: null, feedback: [] });
  state.step = "idle";
  $("result").hidden = true;
  $("request").value = $("feedback").value = "";
  hint(message);
}

// ---------- completion: clear 3 s after the user stops tracing ----------

const trackH = () => Math.round((TRACK_W * state.layout.paperH) / state.layout.paperW);

setInterval(() => {
  if (!state.tracker || state.fadeStart || !state.H || !state.detImage) return;
  const now = performance.now();
  // Skip frames while the head (or page) is moving fast: they're blurry and
  // misaligned. A still-enough view comes back within a moment.
  const moving = pageMotion(state.trackH, state.H, state.layout) > video.videoWidth * 0.02;
  state.trackH = state.H;
  if (moving) return;
  const k = det.width / video.videoWidth;
  const Hdet = multiply([k, 0, 0, 0, k, 0, 0, 0, 1], state.H);
  const { paperW, paperH } = state.layout;
  const img = state.detImage;
  const gray = toGray(rectifyRGBA(img.data, img.width, img.height, Hdet, paperW, paperH, TRACK_W, trackH()));
  state.trackState = state.tracker.update(gray, now);
  if (state.trackState.done) state.fadeStart = now;
}, TRACK_MS);

// ---------- controls ----------

function hint(text) {
  state.hintText = text;
  $("hint").textContent = text;
}

$("paper").onchange = () => {
  state.layout = boardLayout($("paper").value);
  if (state.paperTracker) state.paperTracker = new PaperTracker(new AR.Detector(), state.layout);
  $("template").href = `template.html?size=${$("paper").value}`;
  finish("Paper size changed.");
};

$("ask").onclick = () => {
  const text = $("request").value.trim();
  if (state.step === "waiting" || state.step === "listening") return;
  ask(text);
};
$("request").addEventListener("keydown", (e) => e.key === "Enter" && $("ask").click());
$("change").onclick = () => {
  const text = $("feedback").value.trim();
  if (!text || !state.result || state.step === "waiting") return;
  $("feedback").value = "";
  handleFeedback(text);
};
$("feedback").addEventListener("keydown", (e) => e.key === "Enter" && $("change").click());
$("prev").onclick = () => selectSuggestion(state.index - 1);
$("next").onclick = () => selectSuggestion(state.index + 1);
$("dismiss").onclick = () => finish("Outline hidden.");
$("mic").onclick = () => {
  if (state.step === "listening") return stopListening();
  listen(state.result ? "feedback" : "request");
};
if (!Recognition) $("mic").hidden = true;

$("enter-headset").onclick = async () => {
  try {
    await document.documentElement.requestFullscreen();
    await screen.orientation?.lock?.("landscape");
  } catch {
    // Fullscreen or orientation lock can be refused; the view still works.
  }
  try {
    state.wakeLock = await navigator.wakeLock?.request("screen");
  } catch {
    // Not supported; the screen may dim during long sessions.
  }
  state.headset = true;
  document.body.classList.add("headset");
  resize();
  if (!state.H) hint("Look at your printed page.");
  else if (state.result) hint("Trace it. Tap to ask for changes. It clears 3 s after you stop.");
  else if (state.box) hint("Tap, then say what should go in the box.");
  else hint(idleHint());
};

document.addEventListener("fullscreenchange", () => {
  if (document.fullscreenElement || !state.headset) return;
  state.headset = false;
  state.wakeLock?.release?.();
  document.body.classList.remove("headset");
  resize();
});

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

startCamera();
