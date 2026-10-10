// Planar homography helpers. The paper is a plane, so one 3x3 matrix maps
// paper coordinates to camera pixels (and its inverse maps back). Matrices
// are row-major arrays of 9 numbers.

// Homography taking src[i] -> dst[i] for four point pairs.
export function homographyFromPoints(src, dst) {
  if (src.length !== 4 || dst.length !== 4) throw new Error("need exactly 4 point pairs");
  const A = [];
  const b = [];
  for (let i = 0; i < 4; i++) {
    const [x, y] = src[i];
    const [u, v] = dst[i];
    A.push([x, y, 1, 0, 0, 0, -u * x, -u * y]);
    b.push(u);
    A.push([0, 0, 0, x, y, 1, -v * x, -v * y]);
    b.push(v);
  }
  const h = solve(A, b);
  return [...h, 1];
}

export function applyHomography(H, [x, y]) {
  const w = H[6] * x + H[7] * y + H[8];
  return [(H[0] * x + H[1] * y + H[2]) / w, (H[3] * x + H[4] * y + H[5]) / w];
}

export function invert3x3(m) {
  const [a, b, c, d, e, f, g, h, i] = m;
  const A = e * i - f * h;
  const B = -(d * i - f * g);
  const C = d * h - e * g;
  const det = a * A + b * B + c * C;
  if (Math.abs(det) < 1e-12) throw new Error("singular matrix");
  const s = 1 / det;
  return [
    A * s, -(b * i - c * h) * s, (b * f - c * e) * s,
    B * s, (a * i - c * g) * s, -(a * f - c * d) * s,
    C * s, -(a * h - b * g) * s, (a * e - b * d) * s,
  ];
}

// Homography from paper units (0..paperW, 0..paperH) to the four tapped
// corners, given in order top-left, top-right, bottom-right, bottom-left.
export function paperToImage(corners, paperW, paperH) {
  if (!isConvexQuad(corners)) throw new Error("corners must be tapped in order around the page");
  const paper = [[0, 0], [paperW, 0], [paperW, paperH], [0, paperH]];
  return homographyFromPoints(paper, corners);
}

// True when the points form a convex quadrilateral in a consistent winding.
export function isConvexQuad(pts) {
  if (pts.length !== 4) return false;
  let sign = 0;
  for (let i = 0; i < 4; i++) {
    const [ax, ay] = pts[i];
    const [bx, by] = pts[(i + 1) % 4];
    const [cx, cy] = pts[(i + 2) % 4];
    const cross = (bx - ax) * (cy - by) - (by - ay) * (cx - bx);
    if (Math.abs(cross) < 1e-9) return false;
    if (sign && Math.sign(cross) !== sign) return false;
    sign = Math.sign(cross);
  }
  return true;
}

// Warp a camera frame into a top-down view of the paper.
// src: RGBA bytes (srcW x srcH); H: paper -> src pixels.
// Returns RGBA bytes of size outW x outH covering the whole page.
export function rectifyRGBA(src, srcW, srcH, H, paperW, paperH, outW, outH) {
  const out = new Uint8ClampedArray(outW * outH * 4);
  const sx = paperW / outW;
  const sy = paperH / outH;
  for (let y = 0; y < outH; y++) {
    for (let x = 0; x < outW; x++) {
      const [u, v] = applyHomography(H, [(x + 0.5) * sx, (y + 0.5) * sy]);
      const ui = Math.min(srcW - 1, Math.max(0, u | 0));
      const vi = Math.min(srcH - 1, Math.max(0, v | 0));
      const si = (vi * srcW + ui) * 4;
      const oi = (y * outW + x) * 4;
      out[oi] = src[si];
      out[oi + 1] = src[si + 1];
      out[oi + 2] = src[si + 2];
      out[oi + 3] = 255;
    }
  }
  return out;
}

// Luminance (0..255) of an RGBA buffer.
export function toGray(rgba) {
  const n = rgba.length / 4;
  const g = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    g[i] = 0.299 * rgba[i * 4] + 0.587 * rgba[i * 4 + 1] + 0.114 * rgba[i * 4 + 2];
  }
  return g;
}

// Gaussian elimination with partial pivoting.
function solve(A, b) {
  const n = b.length;
  const M = A.map((row, i) => [...row, b[i]]);
  for (let col = 0; col < n; col++) {
    let pivot = col;
    for (let r = col + 1; r < n; r++) if (Math.abs(M[r][col]) > Math.abs(M[pivot][col])) pivot = r;
    if (Math.abs(M[pivot][col]) < 1e-12) throw new Error("degenerate points (three in a line?)");
    [M[col], M[pivot]] = [M[pivot], M[col]];
    for (let r = 0; r < n; r++) {
      if (r === col) continue;
      const f = M[r][col] / M[col][col];
      for (let c = col; c <= n; c++) M[r][c] -= f * M[col][c];
    }
  }
  return M.map((row, i) => row[n] / row[i]);
}
