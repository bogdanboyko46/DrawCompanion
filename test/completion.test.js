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

const tracker = (strokes = [line], options) =>
  new CompletionTracker({ baseline: blank(), width: W, height: H, ...paper, strokes, options });

test("resample spaces points evenly", () => {
  const pts = resample([[0, 0], [10, 0]], false, 2.5);
  assert.deepEqual(pts.map((p) => p[0]), [0, 2.5, 5, 7.5, 10]);
});

test("tracing the outline completes it after confirmation frames", () => {
  const t = tracker();
  const traced = ink(blank(), 40, 160, 101);
  assert.equal(t.update(traced).done, false);
  assert.equal(t.update(traced).done, false);
  const s = t.update(traced);
  assert.equal(s.done, true);
  assert.ok(s.strokes[0].progress > 0.95);
});

test("partial tracing reports progress but is not done", () => {
  const t = tracker();
  const half = ink(blank(), 40, 100, 100);
  let s;
  for (let i = 0; i < 4; i++) s = t.update(half);
  assert.equal(s.done, false);
  assert.ok(s.strokes[0].progress > 0.4 && s.strokes[0].progress < 0.6, `progress ${s.strokes[0].progress}`);
});

test("ink far from the outline does not count", () => {
  const t = tracker();
  const elsewhere = ink(blank(), 40, 160, 30);
  let s;
  for (let i = 0; i < 5; i++) s = t.update(elsewhere);
  assert.equal(s.strokes[0].progress, 0);
});

test("a hand-sized blob over the outline is not mistaken for ink", () => {
  const t = tracker();
  const hand = blank();
  for (let y = 80; y < 125; y++) for (let x = 30; x < 120; x++) hand[y * W + x] = 150;
  let s;
  for (let i = 0; i < 5; i++) s = t.update(hand);
  assert.equal(s.strokes[0].progress, 0);
});

test("whole-page change is reported as occluded", () => {
  const t = tracker();
  const dark = new Float32Array(W * H).fill(120);
  for (let i = 0; i < dark.length; i += 2) dark[i] = 230; // half the page changes
  assert.equal(t.update(dark).occluded, true);
});

test("uniform lighting change alone is ignored", () => {
  const t = tracker();
  const dimmer = new Float32Array(W * H).fill(170);
  let s;
  for (let i = 0; i < 5; i++) s = t.update(dimmer);
  assert.equal(s.occluded, false);
  assert.equal(s.strokes[0].progress, 0);
});

test("construction lines are not required when contours exist", () => {
  const guide = { role: "construction", closed: false, weight: "light", points: [[200, 200], [800, 200]] };
  const t = tracker([guide, line]);
  const traced = ink(blank(), 40, 160, 100);
  let s;
  for (let i = 0; i < 3; i++) s = t.update(traced);
  assert.equal(s.done, true);
  assert.equal(s.strokes[0].done, false);
});
