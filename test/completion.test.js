import { test } from "node:test";
import assert from "node:assert/strict";
import { CompletionTracker, resample } from "../public/completion.js";

const W = 200;
const H = 200;
const paper = { paperW: 1000, paperH: 1000 };
const blank = () => new Float32Array(W * H).fill(230);
const line = { role: "contour", closed: false, weight: "medium", points: [[200, 500], [800, 500]] };

// Draw a dark horizontal segment in grid pixels.
function ink(img, x0, x1, y, thickness = 1) {
  for (let t = 0; t < thickness; t++) for (let x = x0; x <= x1; x++) img[(y + t) * W + x] = 80;
  return img;
}

const tracker = (baseline = blank(), strokes = [line]) =>
  new CompletionTracker({ baseline, width: W, height: H, ...paper, strokes });

// Feed the same frame at each of the given times; return the last state.
const feed = (t, img, times) => times.map((ms) => t.update(img, ms)).at(-1);

test("resample spaces points evenly", () => {
  const pts = resample([[0, 0], [10, 0]], false, 2.5);
  assert.deepEqual(pts.map((p) => p[0]), [0, 2.5, 5, 7.5, 10]);
});

test("outline clears 3 s after the user stops tracing it", () => {
  const t = tracker();
  const traced = ink(blank(), 40, 160, 101);
  let s = feed(t, traced, [0, 400, 800]); // confirmed as ink at 800 ms
  assert.equal(s.started, true);
  assert.equal(s.done, false);
  assert.equal(feed(t, traced, [2000, 3700]).done, false);
  assert.equal(t.update(traced, 3900).done, true);
});

test("each newly traced section restarts the 3 s countdown", () => {
  const t = tracker();
  const first = ink(blank(), 40, 80, 100);
  feed(t, first, [0, 400, 800]);
  const more = ink(first.slice(), 80, 120, 100);
  feed(t, more, [3000, 3400, 3600]); // new ink confirmed at 3600 ms
  assert.equal(t.update(more, 5000).done, false);
  assert.equal(t.update(more, 6700).done, true);
});

test("outline stays until the user starts tracing", () => {
  const t = tracker();
  assert.equal(feed(t, blank(), [0, 5000, 20000]).done, false);
});

test("partial tracing reports progress", () => {
  const t = tracker();
  const s = feed(t, ink(blank(), 40, 100, 100), [0, 400, 800]);
  assert.ok(s.strokes[0].progress > 0.4 && s.strokes[0].progress < 0.6, `progress ${s.strokes[0].progress}`);
});

test("ink far from the outline does not count", () => {
  const t = tracker();
  const s = feed(t, ink(blank(), 40, 160, 30), [0, 400, 800, 1200, 5000]);
  assert.equal(s.strokes[0].progress, 0);
  assert.equal(s.started, false);
});

test("a hand resting on the outline isn't ink but holds the outline up", () => {
  const t = tracker();
  const traced = ink(blank(), 40, 100, 100);
  feed(t, traced, [0, 400, 800]);
  const hand = traced.slice();
  for (let y = 80; y < 125; y++) for (let x = 110; x < 170; x++) hand[y * W + x] = 150;
  const s = feed(t, hand, [2000, 3000, 4000, 5000]);
  assert.equal(s.done, false);
  assert.ok(s.strokes[0].progress < 0.6, "the hand was counted as tracing");
  assert.equal(t.update(traced, 7900).done, false); // hand last seen at 5000 ms
  assert.equal(t.update(traced, 8100).done, true);
});

test("whole-page change is reported as occluded and holds the outline", () => {
  const t = tracker();
  const traced = ink(blank(), 40, 160, 100);
  feed(t, traced, [0, 400, 800]);
  const busy = new Float32Array(W * H).fill(120);
  for (let i = 0; i < busy.length; i += 2) busy[i] = 230;
  assert.equal(t.update(busy, 3500).occluded, true);
  assert.equal(t.update(traced, 4000).done, false);
});

test("uniform lighting change alone is ignored", () => {
  const t = tracker();
  const s = feed(t, new Float32Array(W * H).fill(170), [0, 400, 800, 1200]);
  assert.equal(s.occluded, false);
  assert.equal(s.strokes[0].progress, 0);
});

test("existing lines that shift a pixel or two are not new ink", () => {
  // The page already has a line right on the outline; tracking jitter moves it.
  const base = ink(blank(), 40, 160, 100);
  const t = tracker(base);
  const shifted = ink(blank(), 41, 161, 102);
  const s = feed(t, shifted, [0, 400, 800, 1200]);
  assert.equal(s.strokes[0].progress, 0);
});
