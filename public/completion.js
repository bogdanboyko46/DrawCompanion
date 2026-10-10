// Decides when the outline should go away: once the user has started tracing
// it and then hasn't drawn on it for 3 seconds. Works on top-down grayscale
// views of the paper:
//
//   baseline = the page when the suggestion appeared
//   current  = the page now
//
// New ink shows up as pixels that got darker. Each stroke is sampled into
// points; a point counts as traced once new ink appears near it in several
// consecutive frames. Things that look like ink but aren't:
//   - a hand or pencil over the page: a large *blob* of change, not a thin
//     line. It isn't counted as ink, but it does keep the outline up, since
//     a hand on the outline means the user is probably still drawing.
//   - lighting shifts: overall brightness is matched to the baseline
//   - small tracking misalignment (the camera is on your head): a pixel only
//     counts if it's darker than everything near it in the baseline, so
//     existing lines that shift a pixel or two don't register as new ink

const DEFAULTS = {
  idleMs: 3000, // clear the outline after this long without drawing on it
  darkerBy: 28, // gray levels a pixel must darken to count as ink
  alignPx: 2, // tolerated misalignment between baseline and current, in grid pixels
  hitRadius: 0.018, // tolerance around the outline, as a fraction of page width
  blobRadius: 0.05, // window for the "is this a thin line?" test
  // A traced line fills roughly thickness/(2*blobRadius) of the window; a
  // crossing doubles that. The edge of a hand fills far more.
  blobFraction: 0.3,
  frameOccludedFraction: 0.15, // more of the page changed than this = hand over the page
  confirmFrames: 3, // consecutive frames a point must look inked
  strokeDoneAt: 0.8, // fraction of a stroke traced to show it as done
  sampleSpacing: 0.012, // distance between samples along a stroke, fraction of page width
};

export class CompletionTracker {
  constructor({ baseline, width, height, paperW, paperH, strokes, options = {}, now = 0 }) {
    this.opts = { ...DEFAULTS, ...options };
    this.w = width;
    this.h = height;
    this.baseline = minFilter(baseline, width, height, this.opts.alignPx);
    this.baseMean = mean(baseline);
    const toGrid = ([x, y]) => [
      Math.min(width - 1, Math.max(0, Math.round((x / paperW) * width))),
      Math.min(height - 1, Math.max(0, Math.round((y / paperH) * height))),
    ];
    const spacing = this.opts.sampleSpacing * paperW;
    this.strokes = strokes.map((s) => {
      const samples = resample(s.points, s.closed, spacing).map(toGrid);
      return {
        samples,
        streak: new Uint8Array(samples.length),
        traced: new Uint8Array(samples.length),
        progress: 0,
        done: false,
      };
    });
    this.started = false; // has the user drawn on the outline at all?
    this.lastActivity = now;
    this.done = false;
  }

  // current: grayscale page, same size as the baseline. now: milliseconds.
  update(current, now) {
    if (this.done) return this.#state(false, now);
    const { w, h, opts } = this;
    const scale = this.baseMean / Math.max(1, mean(current));
    const changed = new Uint8Array(w * h);
    let changedCount = 0;
    for (let i = 0; i < changed.length; i++) {
      if (this.baseline[i] - current[i] * scale > opts.darkerBy) {
        changed[i] = 1;
        changedCount++;
      }
    }
    if (changedCount / changed.length > opts.frameOccludedFraction) {
      this.lastActivity = now; // hand over the page: assume they're drawing
      return this.#state(true, now);
    }

    const sat = integral(changed, w, h);
    const r = Math.max(1, Math.round(opts.hitRadius * w));
    const R = Math.max(r + 1, Math.round(opts.blobRadius * w));
    let active = false;
    for (const s of this.strokes) {
      let tracedCount = 0;
      s.samples.forEach(([x, y], i) => {
        if (!s.traced[i]) {
          const near = boxSum(sat, w, h, x - r, y - r, x + r, y + r);
          if (near === 0) {
            s.streak[i] = 0;
          } else {
            const wide = boxSum(sat, w, h, x - R, y - R, x + R, y + R);
            const area = boxArea(w, h, x - R, y - R, x + R, y + R);
            if (wide / area > opts.blobFraction) {
              active = true; // hand on the outline
            } else if (++s.streak[i] >= opts.confirmFrames) {
              s.traced[i] = 1;
              active = this.started = true;
            }
          }
        }
        tracedCount += s.traced[i];
      });
      s.progress = s.samples.length ? tracedCount / s.samples.length : 1;
      s.done = s.progress >= opts.strokeDoneAt;
    }
    if (active) this.lastActivity = now;
    this.done = this.started && now - this.lastActivity >= opts.idleMs;
    return this.#state(false, now);
  }

  #state(occluded, now) {
    return {
      occluded,
      started: this.started,
      done: this.done,
      idleMs: now - this.lastActivity,
      strokes: this.strokes.map((s) => ({ progress: s.progress, done: s.done })),
    };
  }
}

// Points every `spacing` units along a polyline.
export function resample(points, closed, spacing) {
  const pts = closed ? [...points, points[0]] : points;
  const out = [pts[0]];
  let carry = 0;
  for (let i = 1; i < pts.length; i++) {
    const [x0, y0] = pts[i - 1];
    const [x1, y1] = pts[i];
    const len = Math.hypot(x1 - x0, y1 - y0);
    let d = spacing - carry;
    while (d <= len) {
      const t = d / len;
      out.push([x0 + (x1 - x0) * t, y0 + (y1 - y0) * t]);
      d += spacing;
    }
    carry = len - (d - spacing);
  }
  return out;
}

function mean(a) {
  let s = 0;
  for (let i = 0; i < a.length; i++) s += a[i];
  return s / a.length;
}

// Darkest value within `r` pixels (separable square window).
function minFilter(img, w, h, r) {
  if (r <= 0) return img;
  const tmp = new Float32Array(w * h);
  const out = new Float32Array(w * h);
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++) {
      let m = Infinity;
      for (let k = Math.max(0, x - r); k <= Math.min(w - 1, x + r); k++) m = Math.min(m, img[y * w + k]);
      tmp[y * w + x] = m;
    }
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++) {
      let m = Infinity;
      for (let k = Math.max(0, y - r); k <= Math.min(h - 1, y + r); k++) m = Math.min(m, tmp[k * w + x]);
      out[y * w + x] = m;
    }
  return out;
}

// Summed-area table with a zero border: sat[(y+1)*(w+1) + (x+1)] = sum over [0..x]x[0..y].
function integral(mask, w, h) {
  const W = w + 1;
  const sat = new Uint32Array(W * (h + 1));
  for (let y = 0; y < h; y++) {
    let row = 0;
    for (let x = 0; x < w; x++) {
      row += mask[y * w + x];
      sat[(y + 1) * W + x + 1] = sat[y * W + x + 1] + row;
    }
  }
  return sat;
}

function boxSum(sat, w, h, x0, y0, x1, y1) {
  x0 = Math.max(0, x0);
  y0 = Math.max(0, y0);
  x1 = Math.min(w - 1, x1);
  y1 = Math.min(h - 1, y1);
  const W = w + 1;
  return sat[(y1 + 1) * W + x1 + 1] - sat[y0 * W + x1 + 1] - sat[(y1 + 1) * W + x0] + sat[y0 * W + x0];
}

function boxArea(w, h, x0, y0, x1, y1) {
  return (Math.min(w - 1, x1) - Math.max(0, x0) + 1) * (Math.min(h - 1, y1) - Math.max(0, y0) + 1);
}
