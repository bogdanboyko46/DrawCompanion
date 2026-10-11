// Prompt templates under test. {obj} = what to add, {where} = placement in words.
export const PROMPTS = {
  // keep the user's pencil style (what the cat test used, made stricter)
  pencil: `Edit this photo of a pencil drawing on paper. Add {obj} {where}. Draw it in the same style as the existing drawing: simple thin grey pencil outlines, like a child's doodle, no shading, no colour, no fill, no background. Leave everything that is already on the page exactly as it is: do not move, redraw, resize, restyle or erase any existing line, and keep the paper, lighting, framing and camera position identical. Only add the new lines.`,
  // colour-coded: ONLY the new lines in red, so extraction is a colour test, not a diff
  red: `Edit this image of a pencil drawing on paper. Add {obj} {where}. Draw ONLY the new {short} with clean, smooth, continuous red pen lines: simple line art with a single even line weight, no shading, no hatching, no fill, no other colours. Leave everything that is already on the page exactly as it is: do not move, redraw, resize, restyle, recolour or erase any existing grey pencil line, and keep the paper, framing and position identical. Only add the new red lines.`,
  // no-reference style: the new object alone on blank paper (nothing to register against)
  alone: `This image shows a pencil drawing on paper. Produce the same page with the existing drawing completely ERASED (blank white paper), and only {obj} drawn {where}, in clean continuous red pen lines, simple line art, no shading, no fill. Keep the framing and page position identical, so the new drawing sits exactly where it would go next to the erased drawing.`,
};

export const CASES = {
  "p2-cat": { page: "page-2", obj: "a cat standing next to him", short: "cat", where: "on the empty paper to the LEFT of the figure (the cat should be about as tall as the figure's body and must not touch or overlap him)" },
  "p2-dog": { page: "page-2", obj: "a dog standing next to him", short: "dog", where: "on the paper to the RIGHT of the figure (about as tall as the figure, not touching or overlapping him)" },
  "p3-tree": { page: "page-3", obj: "a tree", short: "tree", where: "on the empty paper to the LEFT of the figure (a tree taller than the figure, not touching him)" },
  "p1-house": { page: "page-1", obj: "a house", short: "house", where: "on the empty RIGHT half of the page (a simple house with a roof, a door and a window, not touching the figure)" },
  "p1-bike": { page: "page-1", obj: "a bicycle", short: "bicycle", where: "on the empty RIGHT side of the page (a side view, not touching the figure)" },
  "p3-hat": { page: "page-3", obj: "a hat on the figure's head", short: "hat", where: "sitting on top of his head, resting on his spiky hair" },
  "p3-teeth": { page: "page-3", obj: "teeth inside the figure's smile", short: "teeth", where: "inside his existing smile line (small square teeth along the smile; do not redraw the smile itself)" },
  "p3-sun": { page: "page-3", obj: "a sun", short: "sun", where: "in the empty top-right corner of the page" },
};

export function fill(template, c) {
  return template.replaceAll("{obj}", c.obj).replaceAll("{where}", c.where).replaceAll("{short}", c.short);
}
