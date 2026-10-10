import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { applyHomography, homographyFromPoints, invert3x3 } from "../public/geometry.js";
import { boardLayout, markerCorners } from "../public/board.js";
import { PaperTracker } from "../public/tracking.js";

const { AR } = createRequire(import.meta.url)("../public/vendor/js-aruco2/aruco.js");
const layout = boardLayout("a4");
const dictionary = new AR.Dictionary("ARUCO_MIP_36h12");

// Is paper point (x, y) black? Renders the markers exactly as template.html prints them.
function paperInk(x, y) {
  for (const m of layout.markers) {
    const cx = Math.floor(((x - m.x) / m.size) * 8);
    const cy = Math.floor(((y - m.y) / m.size) * 8);
    if (cx < 0 || cy < 0 || cx > 7 || cy > 7) continue;
    if (cx === 0 || cy === 0 || cx === 7 || cy === 7) return true;
    return dictionary.codeList[m.id][(cy - 1) * 6 + (cx - 1)] !== "1";
  }
  return false;
}

// Camera image of the page seen through homography H (paper -> pixels).
function photograph(H, width, height) {
  const Hi = invert3x3(H);
  const data = new Uint8ClampedArray(width * height * 4);
  for (let v = 0; v < height; v++) {
    for (let u = 0; u < width; u++) {
      const [x, y] = applyHomography(Hi, [u + 0.5, v + 0.5]);
      const onPage = x >= -40 && y >= -40 && x <= layout.paperW + 40 && y <= layout.paperH + 40;
      const g = !onPage ? 70 : paperInk(x, y) ? 20 : 235;
      data.set([g, g, g, 255], (v * width + u) * 4);
    }
  }
  return { width, height, data };
}

// A tilted, rotated view of the page.
const truth = homographyFromPoints(
  [[0, 0], [layout.paperW, 0], [layout.paperW, layout.paperH], [0, layout.paperH]],
  [[230, 40], [620, 90], [560, 590], [150, 520]],
);

test("least-squares homography fits many noisy-free points exactly", () => {
  const src = layout.markers.flatMap(markerCorners);
  const dst = src.map((p) => applyHomography(truth, p));
  const H = homographyFromPoints(src, dst);
  for (const p of [[0, 0], [500, 700], [1000, 1458]]) {
    const [a, b] = applyHomography(H, p);
    const [c, d] = applyHomography(truth, p);
    assert.ok(Math.hypot(a - c, b - d) < 1e-6);
  }
});

test("finds all markers and recovers the page pose", () => {
  const tracker = new PaperTracker(new AR.Detector(), layout);
  const { H, markers } = tracker.update(photograph(truth, 800, 640));
  assert.deepEqual([...markers].sort(), [0, 1, 2, 3, 4, 5]);
  for (const p of [[0, 0], [1000, 0], [500, 700], [0, layout.paperH]]) {
    const [a, b] = applyHomography(H, p);
    const [c, d] = applyHomography(truth, p);
    assert.ok(Math.hypot(a - c, b - d) < 4, `off by ${Math.hypot(a - c, b - d).toFixed(1)}px at ${p}`);
  }
});

test("still tracks with most markers hidden", () => {
  const img = photograph(truth, 800, 640);
  // Cover everything but the top-left marker (a hand, or looking closely).
  const [mx, my] = applyHomography(truth, [150, 150]);
  for (let v = 0; v < img.height; v++)
    for (let u = 0; u < img.width; u++)
      if (u > mx || v > my) img.data.set([235, 235, 235, 255], (v * img.width + u) * 4);
  const { H, markers } = new PaperTracker(new AR.Detector(), layout).update(img);
  assert.deepEqual(markers, [0]);
  const [a, b] = applyHomography(H, [300, 300]);
  const [c, d] = applyHomography(truth, [300, 300]);
  assert.ok(Math.hypot(a - c, b - d) < 10);
});

test("returns no pose when the page is not in view", () => {
  const blank = { width: 320, height: 240, data: new Uint8ClampedArray(320 * 240 * 4).fill(200) };
  assert.equal(new PaperTracker(new AR.Detector(), layout).update(blank).H, null);
});

test("detection on a downscaled frame maps back to full resolution", () => {
  const half = homographyFromPoints(
    [[0, 0], [layout.paperW, 0], [layout.paperW, layout.paperH], [0, layout.paperH]],
    [[115, 20], [310, 45], [280, 295], [75, 260]],
  );
  const { H } = new PaperTracker(new AR.Detector(), layout).update(photograph(half, 400, 320), 2);
  const [a, b] = applyHomography(H, [1000, 0]);
  assert.ok(Math.hypot(a - 620, b - 90) < 8);
});
