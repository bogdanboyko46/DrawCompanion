// Canned turns with the same streamed events as runTurn(), so the client can
// be developed and demoed without API calls. Words decide the action;
// anything that sounds like a request draws a simple flower, one stroke at a
// time like the real model. delayMs simulates model latency.

import { flattenPath } from "./path.js";
import { toStrokes } from "./suggest.js";

export async function mockTurn({ paper, utterances, current, signal, emit, delayMs = 0 }) {
  const said = utterances.join(" ").toLowerCase();
  await sleep(delayMs * 0.3, signal); // the filter

  let action = "ignore";
  if (/\b(clear|hide|never ?mind|got it)\b/.test(said)) action = current ? "hide" : "ignore";
  else if (/\b(add|draw|put|make|give|show|stuck|what)\b/.test(said)) {
    action = current && /\b(bigger|smaller|move|make it|instead)\b/.test(said) ? "revise" : "new";
  }
  emit({ type: "action", action });
  if (action !== "new" && action !== "revise") {
    emit({ type: "done" });
    return { action, note: "mock" };
  }

  const scale = /\bbigger\b/.test(said) ? 1.3 : /\bsmaller\b/.test(said) ? 0.7 : 1;
  const base = (action === "revise" && bounds(current, paper)) || { x: paper.w * 0.55, y: paper.h * 0.55, w: paper.w * 0.35, h: paper.h * 0.35 };
  const box = { x: base.x + (base.w * (1 - scale)) / 2, y: base.y + (base.h * (1 - scale)) / 2, w: base.w * scale, h: base.h * scale };
  const paths = flowerPaths(box);
  for (const p of paths) {
    await sleep((delayMs * 0.7) / paths.length, signal);
    for (const stroke of toStrokes(JSON.stringify(p), paper)) emit({ type: "stroke", stroke });
  }
  emit({ type: "done" });
  return { action, note: "mock flower" };
}

function bounds(current, paper) {
  const pts = (current?.suggestion.strokes ?? []).flatMap((s) => flattenPath(s.d, paper).flatMap((f) => f.points));
  if (!pts.length) return null;
  const xs = pts.map((p) => p[0]);
  const ys = pts.map((p) => p[1]);
  const x = Math.min(...xs);
  const y = Math.min(...ys);
  return { x, y, w: Math.max(...xs) - x, h: Math.max(...ys) - y };
}

// The flower as the model would write it: a few curves per stroke.
function flowerPaths(box) {
  const r = Math.round;
  const cx = box.x + box.w / 2;
  const s = Math.min(box.w, box.h);
  const cy = box.y + s * 0.3;
  const circle = (rad) =>
    `M ${r(cx - rad)} ${r(cy)} C ${r(cx - rad)} ${r(cy - rad * 1.33)} ${r(cx + rad)} ${r(cy - rad * 1.33)} ${r(cx + rad)} ${r(cy)} ` +
    `C ${r(cx + rad)} ${r(cy + rad * 1.33)} ${r(cx - rad)} ${r(cy + rad * 1.33)} ${r(cx - rad)} ${r(cy)} Z`;
  const petal = (a) => {
    const at = (along, side) => [cx + Math.cos(a) * along - Math.sin(a) * side, cy + Math.sin(a) * along + Math.cos(a) * side].map(r);
    const [p0, p1, c1, c2] = [at(s * 0.08, 0), at(s * 0.26, 0), at(s * 0.17, s * 0.12), at(s * 0.17, -s * 0.12)];
    return `M ${p0.join(" ")} Q ${c1.join(" ")} ${p1.join(" ")} Q ${c2.join(" ")} ${p0.join(" ")} Z`;
  };
  return [
    { role: "construction", weight: "light", d: circle(s * 0.27) },
    { role: "construction", weight: "light", d: `M ${r(cx)} ${r(cy)} L ${r(cx)} ${r(box.y + box.h)}` },
    { role: "contour", weight: "medium", d: circle(s * 0.08) },
    ...Array.from({ length: 6 }, (_, i) => ({ role: "contour", weight: "medium", d: petal((i / 6) * Math.PI * 2) })),
    {
      role: "contour",
      weight: "medium",
      d: `M ${r(cx)} ${r(cy + s * 0.27)} Q ${r(cx + s * 0.06)} ${r((cy + box.y + box.h) / 2)} ${r(cx)} ${r(box.y + box.h)}`,
    },
  ];
}

const sleep = (ms, signal) =>
  new Promise((resolve, reject) => {
    if (!ms) return resolve();
    const t = setTimeout(resolve, ms);
    signal?.addEventListener("abort", () => {
      clearTimeout(t);
      reject(signal.reason);
    });
  });
