import { test } from "node:test";
import assert from "node:assert/strict";
import { applyHomography, homographyFromPoints, invert3x3, rectifyRGBA } from "../public/geometry.js";

const pageToImage = (corners, w, h) => homographyFromPoints([[0, 0], [w, 0], [w, h], [0, h]], corners);

const close = (a, b, eps = 1e-6) => assert.ok(Math.abs(a - b) < eps, `${a} != ${b}`);

test("homography maps page corners onto image corners", () => {
  const corners = [[120, 80], [530, 95], [600, 470], [70, 440]];
  const H = pageToImage(corners, 1000, 1414);
  const paper = [[0, 0], [1000, 0], [1000, 1414], [0, 1414]];
  paper.forEach((p, i) => {
    const [u, v] = applyHomography(H, p);
    close(u, corners[i][0]);
    close(v, corners[i][1]);
  });
});

test("inverse homography round-trips", () => {
  const H = pageToImage([[10, 20], [300, 15], [320, 400], [5, 380]], 1000, 1294);
  const Hi = invert3x3(H);
  for (const p of [[0, 0], [500, 647], [999, 1], [123, 1200]]) {
    const [x, y] = applyHomography(Hi, applyHomography(H, p));
    close(x, p[0], 1e-6);
    close(y, p[1], 1e-6);
  }
});

test("rectify recovers an axis-aligned page", () => {
  // 4x4 source with a red pixel at (3, 0); page occupies the whole frame.
  const src = new Uint8ClampedArray(4 * 4 * 4).fill(255);
  src[(0 * 4 + 3) * 4 + 1] = 0;
  src[(0 * 4 + 3) * 4 + 2] = 0;
  const H = pageToImage([[0, 0], [4, 0], [4, 4], [0, 4]], 100, 100);
  const out = rectifyRGBA(src, 4, 4, H, 100, 100, 4, 4);
  assert.deepEqual([...out.slice(12, 16)], [255, 0, 0, 255]);
  assert.deepEqual([...out.slice(0, 4)], [255, 255, 255, 255]);
});
