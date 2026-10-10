// DrawCompanion web client.
//
// The phone sits in a lightweight headset viewer; its camera shows your page
// to both eyes with the outline on top. The microphone is always on: you
// talk naturally, and every finished phrase goes to the AI with a photo of
// the page. The AI never answers back. It only draws a new outline (placed
// wherever it judges best), changes the current one, clears it, or ignores
// speech that wasn't meant for it. The outline clears by itself 3 s after
// you stop tracing it.
//
// The page is found every frame from the printed template's markers, so the
// outline stays on the paper while your head (or the paper) moves.

import { applyHomography, multiply, rectifyRGBA, toGray } from "./geometry.js";
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
  layout: boardLayout($("paper").value),
  paperTracker: null,
  H: null, // paper -> video pixels, null when the page isn't visible
  lastSeen: 0,
  detImage: null,
  outline: null, // { suggestion, history: [what was said that produced it] }
  tracker: null,
  trackState: null,
  trackH: null,
  fadeStart: 0,
  error: "", // shown briefly in the headset; never an AI reply
  errorUntil: 0,
};

// What the user said that the AI hasn't finished acting on, the request in
// flight, and how to undo a half-drawn outline if that request is cancelled.
const turn = { pending: [], inflight: null, rollback: null };

// ---------- camera, tracking, render loop ----------

async function startCamera() {
  try {
    video.srcObject = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: "environment", width: { ideal: 1920 }, height: { ideal: 1080 } },
      audio: false,
    });
    await video.play();
  } catch (err) {
    status(`Camera unavailable: ${err.message}. Use https or localhost and allow camera access.`, true);
    return;
  }
  det.width = DETECT_W;
  det.height = Math.round((DETECT_W * video.videoHeight) / video.videoWidth);
  state.paperTracker = new PaperTracker(new AR.Detector(), state.layout);
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
  // Something was said while the page was out of view: send it now.
  if (state.H && turn.pending.length && !turn.inflight) sendTurn();
  render(now);
  requestAnimationFrame(frame);
}

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

// Each viewport shows a crop of the camera image: canvas rect plus the
// transform from video pixels into it.
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
    if (state.H && state.outline) drawOutline(now);
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    if (state.headset) drawHud(vp, now);
    ctx.restore();
  }
}

const unit = () => video.videoWidth / 640;

const ROLE_STYLE = {
  construction: { width: 1.5, dash: [6, 5], alpha: 0.6 },
  contour: { width: 3, dash: [], alpha: 1 },
  detail: { width: 2, dash: [], alpha: 0.9 },
  shading: { width: 1.5, dash: [2, 4], alpha: 0.7 },
};
const WEIGHT = { light: 0.75, medium: 1, bold: 1.4 };

function drawOutline(now) {
  let fade = 1;
  if (state.fadeStart) {
    fade = Math.max(0, 1 - (now - state.fadeStart) / 900);
    if (fade === 0) return clearOutline();
  }
  state.outline.suggestion.strokes.forEach((st, i) => {
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
  if (points.length < 2) return;
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

// Headset status, without words: a small dot low in each eye.
//   green = listening, pulsing blue = working on what you said,
//   orange = can't see the page, grey = microphone off.
// Text appears only for setup problems (camera, microphone, server).
function drawHud(vp, now) {
  const s = vp.h / 400;
  const cx = vp.x + vp.w / 2;
  const cy = vp.y + vp.h * 0.93;
  const color = !state.H ? "#ff8a3d" : turn.inflight ? "#19c3ff" : voice.on ? "#3ddc84" : "#888";
  ctx.globalAlpha = turn.inflight ? 0.5 + 0.5 * Math.sin(now / 150) : 0.9;
  ctx.fillStyle = color;
  ctx.beginPath();
  ctx.arc(cx, cy, 3.5 * s, 0, Math.PI * 2);
  ctx.fill();
  ctx.globalAlpha = 1;
  if (state.error && now < state.errorUntil) {
    ctx.font = `${10 * s}px system-ui, sans-serif`;
    ctx.textAlign = "center";
    ctx.fillStyle = "rgb(0 0 0 / 0.6)";
    const w = Math.min(vp.w * 0.9, ctx.measureText(state.error).width + 12 * s);
    ctx.fillRect(cx - w / 2, cy - 22 * s, w, 14 * s);
    ctx.fillStyle = "#fff";
    ctx.fillText(state.error, cx, cy - 12 * s, vp.w * 0.88);
    ctx.textAlign = "start";
  }
}

// ---------- always-on voice ----------

const voice = { on: false, rec: null, startedAt: 0, delay: 250 };

function startListening() {
  if (!Recognition) return status("This browser has no speech input. Type below instead.", true);
  if (voice.on) return;
  voice.on = true;
  openMic();
  status("Listening. Just talk about what you want.");
  $("listen").textContent = "Stop listening";
}

function stopListening() {
  voice.on = false;
  voice.rec?.stop();
  $("listen").textContent = "Start listening";
  status("Microphone off.");
}

// Browsers end recognition sessions after silence or a time limit; reopen
// them for as long as listening is on, backing off if they fail fast.
function openMic() {
  const rec = new Recognition();
  rec.continuous = true;
  rec.interimResults = false;
  rec.lang = navigator.language || "en-US";
  rec.onresult = (e) => {
    for (let i = e.resultIndex; i < e.results.length; i++) {
      if (e.results[i].isFinal) heard(e.results[i][0].transcript);
    }
  };
  rec.onerror = (e) => {
    if (e.error === "not-allowed" || e.error === "service-not-allowed") {
      stopListening();
      status("Microphone blocked. Allow it in the browser settings.", true);
    }
  };
  rec.onend = () => {
    voice.rec = null;
    if (!voice.on) return;
    voice.delay = performance.now() - voice.startedAt < 1000 ? Math.min(voice.delay * 2, 5000) : 250;
    setTimeout(() => voice.on && !voice.rec && openMic(), voice.delay);
  };
  voice.startedAt = performance.now();
  voice.rec = rec;
  rec.start();
}

function heard(text) {
  text = text.trim();
  if (!text) return;
  $("heard").textContent = `Heard: “${text}”`;
  turn.pending.push(text);
  sendTurn();
}

// ---------- turns: what you said -> the AI's action ----------

async function sendTurn() {
  // You kept talking: the in-flight turn is out of date. Cancel it, put back
  // any outline it had started drawing, and send everything said since the
  // last completed turn together.
  turn.inflight?.abort();
  turn.inflight = null;
  turn.rollback?.();
  turn.rollback = null;
  if (!state.H) return; // sent from frame() once the page is back in view

  const utterances = turn.pending.slice();
  const { image, baseline } = capturePage();
  const controller = new AbortController();
  turn.inflight = controller;
  let action = null;
  let incoming = null;
  try {
    const res = await fetch("/api/turn", {
      method: "POST",
      headers: { "content-type": "application/json" },
      signal: controller.signal,
      body: JSON.stringify({
        image,
        paper: { w: state.layout.paperW, h: state.layout.paperH },
        utterances,
        // Only the compact path data goes back; the server doesn't need points.
        current: state.outline && {
          history: state.outline.history,
          suggestion: { strokes: state.outline.suggestion.strokes.map(({ role, weight, d }) => ({ role, weight, d })) },
        },
      }),
    });
    if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error || `HTTP ${res.status}`);
    let done = false;
    for await (const event of ndjson(res.body)) {
      if (event.type === "error") throw new Error(event.error);
      if (event.type === "action") {
        action = event.action;
        if (action === "hide") clearOutline();
      } else if (event.type === "stroke") {
        // First stroke: swap the new outline in and draw strokes as they come.
        if (!incoming) incoming = beginOutline(action, utterances);
        incoming.suggestion.strokes.push(event.stroke);
      } else if (event.type === "done") {
        done = true;
        turn.pending = turn.pending.slice(utterances.length);
        turn.rollback = null;
        if (incoming) startTracking(incoming, baseline);
      }
    }
    if (!done) throw new Error("connection closed early");
  } catch (err) {
    if (err.name === "AbortError") return; // superseded; rollback already done
    turn.rollback?.();
    turn.rollback = null;
    turn.pending = turn.pending.slice(utterances.length); // don't retry forever
    status(`Couldn't reach the AI: ${err.message}`, true);
  } finally {
    if (turn.inflight === controller) turn.inflight = null;
  }
}

// Newline-delimited JSON events from a streamed response body.
async function* ndjson(body) {
  const reader = body.pipeThrough(new TextDecoderStream()).getReader();
  let buf = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += value;
    let nl;
    while ((nl = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, nl).trim();
      buf = buf.slice(nl + 1);
      if (line) yield JSON.parse(line);
    }
  }
}

// Show a new outline that is still arriving. Clearing is paused until it's
// complete; if the turn is cancelled first, the previous outline comes back.
function beginOutline(action, utterances) {
  const previous = { outline: state.outline, tracker: state.tracker, trackState: state.trackState, fadeStart: state.fadeStart };
  turn.rollback = () => {
    Object.assign(state, previous);
    $("hide").disabled = !state.outline;
  };
  const history = action === "revise" && state.outline ? [...state.outline.history, ...utterances] : utterances;
  const outline = { suggestion: { strokes: [] }, history };
  Object.assign(state, { outline, tracker: null, trackState: null, fadeStart: 0 });
  $("hide").disabled = false;
  return outline;
}

function startTracking(outline, baseline) {
  if (state.outline !== outline) return;
  state.tracker = new CompletionTracker({
    baseline,
    width: TRACK_W,
    height: trackH(),
    paperW: state.layout.paperW,
    paperH: state.layout.paperH,
    strokes: outline.suggestion.strokes,
    now: performance.now(),
  });
}

function clearOutline() {
  Object.assign(state, { outline: null, tracker: null, trackState: null, fadeStart: 0 });
  $("hide").disabled = true;
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

// ---------- controls (phone view) ----------

// Status line for the phone view. Problems also flash in the headset.
function status(text, isError = false) {
  $("hint").textContent = text;
  if (isError) {
    state.error = text;
    state.errorUntil = performance.now() + 4000;
  }
}

$("paper").onchange = () => {
  state.layout = boardLayout($("paper").value);
  if (state.paperTracker) state.paperTracker = new PaperTracker(new AR.Detector(), state.layout);
  $("template").href = `template.html?size=${$("paper").value}`;
  clearOutline();
};

$("listen").onclick = () => (voice.on ? stopListening() : startListening());
$("say").addEventListener("keydown", (e) => {
  if (e.key !== "Enter") return;
  heard($("say").value);
  $("say").value = "";
});
$("hide").onclick = clearOutline;

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
  startListening();
};

document.addEventListener("fullscreenchange", () => {
  if (document.fullscreenElement || !state.headset) return;
  state.headset = false;
  state.wakeLock?.release?.();
  document.body.classList.remove("headset");
  resize();
});

// ?debug exposes internals for inspection from the console or test scripts.
if (new URLSearchParams(location.search).has("debug")) window.drawcompanion = { state, turn };

status("Point the camera at your printed DrawCompanion page, then start listening.");
startCamera();
