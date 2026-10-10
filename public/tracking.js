// Finds the drawing template in a camera frame and returns the homography
// from paper units to camera pixels. Runs every frame: in a headset the
// camera moves with your head, so a one-time calibration can't work.

import { applyHomography, homographyFromPoints } from "./geometry.js";
import { markerCorners } from "./board.js";

export class PaperTracker {
  // detector: an AR.Detector (js-aruco2, ARUCO_MIP_36h12)
  constructor(detector, layout, { deadbandPx = 1.2 } = {}) {
    this.detector = detector;
    this.layout = layout;
    this.deadbandPx = deadbandPx;
    this.byId = new Map(layout.markers.map((m) => [m.id, markerCorners(m)]));
    this.H = null;
  }

  // image: {width, height, data} (e.g. ImageData). scale: multiply detected
  // pixel coordinates by this to get camera pixels (when detecting on a
  // downscaled frame). Returns {H, markers} with H = null if the page isn't visible.
  update(image, scale = 1) {
    const src = [];
    const dst = [];
    const seen = [];
    for (const m of this.detector.detect(image)) {
      const paper = this.byId.get(m.id);
      if (!paper) continue;
      seen.push(m.id);
      m.corners.forEach((c, i) => {
        src.push(paper[i]);
        dst.push([c.x * scale, c.y * scale]);
      });
    }
    if (!seen.length) return { H: (this.H = null), markers: seen };

    let H;
    try {
      H = homographyFromPoints(src, dst);
    } catch {
      return { H: (this.H = null), markers: seen };
    }
    // Ignore sub-pixel jitter so a still page gives a still outline.
    if (pageMotion(this.H, H, this.layout) < this.deadbandPx) H = this.H;
    this.H = H;
    return { H, markers: seen };
  }
}

// Largest movement of the page's corners between two homographies, in pixels.
export function pageMotion(a, b, layout) {
  if (!a || !b) return Infinity;
  const { paperW: w, paperH: h } = layout;
  return Math.max(
    ...[[0, 0], [w, 0], [w, h], [0, h]].map((p) => {
      const [x0, y0] = applyHomography(a, p);
      const [x1, y1] = applyHomography(b, p);
      return Math.hypot(x1 - x0, y1 - y0);
    }),
  );
}
