// The printable drawing template. Six ArUco markers (ARUCO_MIP_36h12, ids
// 0-5) sit inside the corners and at the middle of the long edges of a
// "drawing frame". Paper coordinates are defined by that frame: (0, 0) is its
// top-left, it is PAPER_W units wide, and its height follows its aspect ratio.
// Because everything is measured from the markers, the paper can move or
// rotate freely and printer scaling doesn't matter.

export const PAPER_W = 1000;

const SHEETS = {
  a4: { label: "A4", w: 210, h: 297 },
  letter: { label: "US Letter", w: 215.9, h: 279.4 },
};
const MARGIN_MM = 10;
const MARKER_MM = 24; // black square; the printed quiet zone adds one cell around it

export function boardLayout(size = "a4") {
  const sheet = SHEETS[size] ?? SHEETS.a4;
  const frameW = sheet.w - 2 * MARGIN_MM;
  const frameH = sheet.h - 2 * MARGIN_MM;
  const k = PAPER_W / frameW; // paper units per mm
  const paperH = Math.round(frameH * k);
  const s = MARKER_MM * k;
  const midY = (paperH - s) / 2;
  const at = [
    [0, 0], // 0 top-left
    [PAPER_W - s, 0], // 1 top-right
    [PAPER_W - s, paperH - s], // 2 bottom-right
    [0, paperH - s], // 3 bottom-left
    [0, midY], // 4 middle-left
    [PAPER_W - s, midY], // 5 middle-right
  ];
  return {
    size: SHEETS[size] ? size : "a4",
    sheet,
    marginMm: MARGIN_MM,
    markerMm: MARKER_MM,
    frameMm: { w: frameW, h: frameH },
    paperW: PAPER_W,
    paperH,
    markers: at.map(([x, y], id) => ({ id, x, y, size: s })),
  };
}

// Paper-unit positions of a marker's black-square corners, in the order the
// detector reports them (clockwise from the printed top-left).
export function markerCorners({ x, y, size }) {
  return [[x, y], [x + size, y], [x + size, y + size], [x, y + size]];
}
