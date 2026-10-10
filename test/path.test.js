import { test } from "node:test";
import assert from "node:assert/strict";
import { flattenPath, StrokeScanner } from "../server/path.js";

const paper = { w: 1000, h: 1458 };

test("straight lines keep their corners", () => {
  const [s] = flattenPath("M 100 100 L 200 100 L 200 200", paper);
  assert.deepEqual(s.points, [[100, 100], [200, 100], [200, 200]]);
  assert.equal(s.closed, false);
});

test("curves are flattened through their end points", () => {
  const [s] = flattenPath("M 0 0 C 0 100 100 100 100 0 Q 150 -50 200 0", paper);
  assert.ok(s.points.length > 20);
  assert.deepEqual(s.points.at(-1), [200, 0]);
  const mid = s.points[6]; // t = 0.5 on the cubic
  assert.ok(Math.abs(mid[0] - 50) < 1e-9 && Math.abs(mid[1] - 75) < 1e-9);
});

test("Z closes, H/V work, and each M starts a new stroke", () => {
  const strokes = flattenPath("M 10 10 H 50 V 50 Z M 300 300 L 400 400", paper);
  assert.equal(strokes.length, 2);
  assert.equal(strokes[0].closed, true);
  assert.deepEqual(strokes[0].points, [[10, 10], [50, 10], [50, 50]]);
  assert.match(strokes[1].d, /^M 300 300 L 400 400$/);
});

test("points are clamped to the page; bad input yields nothing", () => {
  const [s] = flattenPath("M -20 50 L 2000 1600", paper);
  assert.deepEqual(s.points, [[0, 50], [1000, 1458]]);
  assert.deepEqual(flattenPath("M 1 1 A 5 5 0 0 1 9 9", paper), []);
  assert.deepEqual(flattenPath("hello", paper), []);
  assert.deepEqual(flattenPath("M 5 5", paper), []);
});

test("a truncated path keeps its complete segments", () => {
  const [s] = flattenPath("M 0 0 L 10 10 C 1 2 3", paper);
  assert.deepEqual(s.points, [[0, 0], [10, 10]]);
});

test("scanner yields each stroke as soon as its object closes, across chunk splits", () => {
  const json = JSON.stringify({ strokes: [
    { role: "contour", weight: "medium", d: "M 1 2 L 3 4" },
    { role: "detail", weight: "light", d: 'M 5 6 L 7 8 "}{' },
  ] });
  const sc = new StrokeScanner();
  const out = [];
  for (let i = 0; i < json.length; i += 7) out.push(...sc.push(json.slice(i, i + 7)).map((t) => JSON.parse(t)));
  assert.equal(out.length, 2);
  assert.equal(out[1].d, 'M 5 6 L 7 8 "}{');
  // The first stroke is available before the second one is complete.
  const early = new StrokeScanner().push(json.slice(0, json.indexOf("detail")));
  assert.equal(early.length, 1);
});
