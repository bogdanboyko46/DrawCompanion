// Planar homography helpers. The paper is a plane, so one 3x3 matrix maps
// paper coordinates to camera pixels (and its inverse maps back). Matrices
// are row-major arrays of 9 numbers.

// Least-squares homography taking src[i] -> dst[i] (at least 4 pairs).
// Points are normalized first (Hartley) so pixel- and paper-scale
// coordinates don't wreck the conditioning.
export function homographyFromPoints(src, dst) {
  if (src.length < 4 || src.length !== dst.length) throw new Error("need at least 4 point pairs");
  const Ts = normalizer(src);
  const Td = normalizer(dst);
  const ATA = Array.from({ length: 8 }, () => new Array(8).fill(0));
  const ATb = new Array(8).fill(0);
  const add = (row, rhs) => {
    for (let i = 0; i < 8; i++) {
      ATb[i] += row[i] * rhs;
      for (let j = 0; j < 8; j++) ATA[i][j] += row[i] * row[j];
    }
  };
  for (let i = 0; i < src.length; i++) {
    const [x, y] = applyHomography(Ts, src[i]);
    const [u, v] = applyHomography(Td, dst[i]);
    add([x, y, 1, 0, 0, 0, -u * x, -u * y], u);
    add([0, 0, 0, x, y, 1, -v * x, -v * y], v);
  }
  const Hn = [...solve(ATA, ATb), 1];
  const H = multiply(invert3x3(Td), multiply(Hn, Ts));
  return H.map((h) => h / H[8]);
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

export function multiply(a, b) {
  const m = new Array(9);
  for (let r = 0; r < 3; r++)
    for (let c = 0; c < 3; c++) m[r * 3 + c] = a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c];
  return m;
}

// Similarity transform moving points to their centroid, mean distance sqrt(2).
function normalizer(pts) {
  const cx = pts.reduce((s, p) => s + p[0], 0) / pts.length;
  const cy = pts.reduce((s, p) => s + p[1], 0) / pts.length;
  const d = pts.reduce((s, p) => s + Math.hypot(p[0] - cx, p[1] - cy), 0) / pts.length || 1;
  const k = Math.SQRT2 / d;
  return [k, 0, -k * cx, 0, k, -k * cy, 0, 0, 1];
}

// Gaussian elimination with partial pivoting.
function solve(A, b) {
  const n = b.length;
  const M = A.map((row, i) => [...row, b[i]]);
  for (let col = 0; col < n; col++) {
    let pivot = col;
    for (let r = col + 1; r < n; r++) if (Math.abs(M[r][col]) > Math.abs(M[pivot][col])) pivot = r;
    if (Math.abs(M[pivot][col]) < 1e-12) throw new Error("degenerate points");
    [M[col], M[pivot]] = [M[pivot], M[col]];
    for (let r = 0; r < n; r++) {
      if (r === col) continue;
      const f = M[r][col] / M[col][col];
      for (let c = col; c <= n; c++) M[r][c] -= f * M[col][c];
    }
  }
  return M.map((row, i) => row[n] / row[i]);
}
