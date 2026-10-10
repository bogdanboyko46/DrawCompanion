// Canned response with the same shape as suggest(), so the client can be
// developed and demoed without API calls. Draws a simple flower sized to the
// marked region (or the lower-right quarter of the page).

export function mockSuggestion({ region, paper, mode, revision }) {
  const box = region ?? { x: paper.w * 0.55, y: paper.h * 0.55, w: paper.w * 0.35, h: paper.h * 0.35 };
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

  const strokes = [
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
  ];

  const suggestion = {
    title: "Six-petal flower",
    placement: box,
    strokes: mode === "scaffold" ? strokes.filter((st) => st.role === "construction") : strokes,
    palette: [
      { hex: "#e8a33d", use: "petals" },
      { hex: "#6b4f2a", use: "center" },
      { hex: "#4f7a3a", use: "stem" },
    ],
    steps: ["Lightly draw the guide circle and stem line", "Add the center, then the petals", "Draw the stem"],
  };
  if (revision) {
    return {
      understood: `Mock revision for: "${revision.feedback.at(-1)}" (mock mode returns the same flower).`,
      style_notes: "Mock response; no image analysis was done.",
      suggestions: [suggestion],
    };
  }
  return {
    understood: "Mock mode: a flower placed in the marked box.",
    style_notes: "Mock response; no image analysis was done.",
    suggestions: mode === "options" ? [suggestion, suggestion, suggestion] : [suggestion],
  };
}
