// Canned decisions with the same shape as decide(), so the client can be
// developed and demoed without API calls. Words decide the action; anything
// that sounds like a request draws a simple flower in the lower right.

export function mockDecision({ paper, utterances, current }) {
  const said = utterances.join(" ").toLowerCase();
  if (/\b(clear|hide|never ?mind|got it)\b/.test(said)) {
    return { action: current ? "hide" : "ignore", note: "mock: hide words", suggestion: null };
  }
  const asks = /\b(add|draw|put|make|give|show|stuck|what)\b/.test(said);
  if (!asks) return { action: "ignore", note: "mock: not a request", suggestion: null };

  const revising = !!current && /\b(bigger|smaller|move|make it|instead)\b/.test(said);
  const scale = /\bbigger\b/.test(said) ? 1.3 : /\bsmaller\b/.test(said) ? 0.7 : 1;
  const base = current?.suggestion.placement ?? { x: paper.w * 0.55, y: paper.h * 0.55, w: paper.w * 0.35, h: paper.h * 0.35 };
  const box = revising
    ? { x: base.x + (base.w * (1 - scale)) / 2, y: base.y + (base.h * (1 - scale)) / 2, w: base.w * scale, h: base.h * scale }
    : base;
  return { action: revising ? "revise" : "new", note: "mock: flower", suggestion: flower(box) };
}

function flower(box) {
  const cx = box.x + box.w / 2;
  const s = Math.min(box.w, box.h);
  const headY = box.y + s * 0.3;
  const circle = (x, y, rad, n = 24) =>
    Array.from({ length: n }, (_, i) => {
      const a = (i / n) * Math.PI * 2;
      return [x + rad * Math.cos(a), y + rad * Math.sin(a)];
    });
  // A petal is a lens shape: out along angle `a` on one side, back on the other.
  const petal = (a) => {
    const pts = [];
    for (const dir of [1, -1]) {
      for (let i = 0; i <= 12; i++) {
        const t = dir === 1 ? i / 12 : 1 - i / 12;
        const along = s * (0.08 + 0.18 * t);
        const side = dir * Math.sin(t * Math.PI) * s * 0.07;
        pts.push([cx + Math.cos(a) * along - Math.sin(a) * side, headY + Math.sin(a) * along + Math.cos(a) * side]);
      }
    }
    return pts;
  };
  return {
    placement: box,
    strokes: [
      { role: "construction", points: circle(cx, headY, s * 0.27), closed: true, weight: "light" },
      { role: "construction", points: [[cx, headY], [cx, box.y + box.h]], closed: false, weight: "light" },
      { role: "contour", points: circle(cx, headY, s * 0.08, 16), closed: true, weight: "medium" },
      ...Array.from({ length: 6 }, (_, i) => ({
        role: "contour",
        points: petal((i / 6) * Math.PI * 2),
        closed: true,
        weight: "medium",
      })),
      {
        role: "contour",
        points: Array.from({ length: 10 }, (_, i) => {
          const t = i / 9;
          return [cx + Math.sin(t * Math.PI) * s * 0.04, headY + s * 0.27 + t * (box.y + box.h - headY - s * 0.27)];
        }),
        closed: false,
        weight: "medium",
      },
    ],
  };
}
