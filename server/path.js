// The drawing model writes each stroke as compact SVG-style path data
// ("M 120 340 C 150 300 200 300 230 340"): a curve costs a few numbers
// instead of dozens of points, which makes the model's output, and so its
// response time, several times shorter. This file turns that path data into
// the polylines the client draws and tracks.
//
// Supported: absolute M, L, H, V, Q, C, Z. Each M starts a separate stroke.

const ARGS = { M: 2, L: 2, H: 1, V: 1, Q: 4, C: 6, Z: 0 };
const SEGMENTS_PER_CURVE = 12;

// Returns [{ d, closed, points }] for one path string, or [] if unusable.
export function flattenPath(d, paper) {
  const tokens = String(d).match(/[A-Za-z]|-?\d*\.?\d+(?:e-?\d+)?/g) ?? [];
  const strokes = [];
  let pts = null;
  let start = null;
  let pen = null;
  let cmd = null;
  let i = 0;
  const num = () => Number(tokens[i++]);
  const finish = (closed) => {
    if (pts && pts.length >= 2) strokes.push({ closed, points: pts });
    pts = null;
  };

  while (i < tokens.length) {
    if (/[A-Za-z]/.test(tokens[i])) {
      cmd = tokens[i++].toUpperCase();
      if (!(cmd in ARGS)) return []; // unknown command: don't guess
      if (cmd === "Z") {
        finish(true);
        pen = start;
        continue;
      }
    } else if (!cmd || cmd === "Z") {
      return [];
    }
    if (i + ARGS[cmd] > tokens.length) break; // truncated: keep what's complete
    if (cmd === "M") {
      finish(false);
      pen = start = [num(), num()];
      pts = [pen];
      cmd = "L"; // extra pairs after M are line-tos
      continue;
    }
    if (!pen) return [];
    pts ??= [pen];
    if (cmd === "L") pen = [num(), num()];
    else if (cmd === "H") pen = [num(), pen[1]];
    else if (cmd === "V") pen = [pen[0], num()];
    else {
      const ctrl = cmd === "Q" ? [[num(), num()]] : [[num(), num()], [num(), num()]];
      const end = [num(), num()];
      for (let s = 1; s <= SEGMENTS_PER_CURVE; s++) pts.push(bezier([pen, ...ctrl, end], s / SEGMENTS_PER_CURVE));
      pen = end;
      continue;
    }
    pts.push(pen);
  }
  finish(false);

  return strokes
    .map((s) => ({ ...s, points: s.points.filter((p) => p.every(Number.isFinite)).map((p) => clampToPage(p, paper)) }))
    .filter((s) => s.points.length >= 2)
    .map((s) => ({ ...s, d: toPathData(s.points, s.closed, d, strokes.length) }));
}

// Keep the model's own path data when it was a single stroke (it's what the
// model will see again when revising); otherwise describe each piece as lines.
function toPathData(points, closed, original, count) {
  if (count === 1) return String(original).trim();
  const r = (v) => Math.round(v);
  return `M ${points.map(([x, y]) => `${r(x)} ${r(y)}`).join(" L ")}${closed ? " Z" : ""}`;
}

// De Casteljau evaluation for quadratic or cubic Bézier control points.
function bezier(ctrl, t) {
  let p = ctrl;
  while (p.length > 1) p = p.slice(1).map((b, k) => [p[k][0] + (b[0] - p[k][0]) * t, p[k][1] + (b[1] - p[k][1]) * t]);
  return p[0];
}

const clampToPage = ([x, y], paper) => [Math.min(paper.w, Math.max(0, x)), Math.min(paper.h, Math.max(0, y))];

// Pulls complete stroke objects out of the model's JSON as it streams in.
// The output is {"strokes":[{...},{...}]}; every time an object inside the
// array closes, its text is returned so it can be drawn right away.
export class StrokeScanner {
  constructor() {
    this.depth = 0;
    this.inString = false;
    this.escaped = false;
    this.buf = "";
    this.start = -1;
  }

  push(text) {
    const done = [];
    for (const ch of text) {
      if (this.start >= 0) this.buf += ch;
      if (this.inString) {
        if (this.escaped) this.escaped = false;
        else if (ch === "\\") this.escaped = true;
        else if (ch === '"') this.inString = false;
        continue;
      }
      if (ch === '"') this.inString = true;
      else if (ch === "{" || ch === "[") {
        this.depth++;
        if (ch === "{" && this.depth === 3) {
          this.start = 0;
          this.buf = "{";
        }
      } else if (ch === "}" || ch === "]") {
        if (ch === "}" && this.depth === 3 && this.start >= 0) {
          done.push(this.buf);
          this.start = -1;
          this.buf = "";
        }
        this.depth--;
      }
    }
    return done;
  }
}
