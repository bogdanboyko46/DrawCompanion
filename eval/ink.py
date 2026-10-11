# Finds the existing pencil lines in each page photo, for the "drawn on top of
# existing lines" score: writes eval/out/<page>-ink.json, a list of [x, y]
# paper-unit cells (2 units apart) that contain ink, and <page>-ink.png to check it.
import json, os
from PIL import Image, ImageFilter

here = os.path.dirname(os.path.abspath(__file__))
cases = json.load(open(os.path.join(here, "cases.json")))
os.makedirs(os.path.join(here, "out"), exist_ok=True)
for name, page in cases["pages"].items():
    paper = page["paper"]
    im = Image.open(os.path.join(here, page["photo"])).convert("RGB")
    w, h = im.size
    lum = im.convert("L")
    bg = lum.filter(ImageFilter.BoxBlur(12))
    px, L, B = im.load(), lum.load(), bg.load()
    k = paper["w"] / w
    cells = set()
    mask = Image.new("L", (w, h), 255)
    M = mask.load()
    # Only near the labeled drawing (stray smudges and shadows aren't parts),
    # and not on the baked-in grid lines, which read as dark in dim light.
    boxes = page["parts"].values()
    x0, y0 = (min(b[0] for b in boxes) - 20) / k, (min(b[1] for b in boxes) - 20) / k
    x1, y1 = (max(b[2] for b in boxes) + 20) / k, (max(b[3] for b in boxes) + 20) / k
    def on_grid(v):
        return min(v % 100, 100 - v % 100) < 3.5
    for y in range(max(0, int(y0)), min(h, int(y1))):
        for x in range(max(0, int(x0)), min(w, int(x1))):
            r, g, b = px[x, y]
            if on_grid(x * k) or on_grid(y * k):
                continue
            if L[x, y] < B[x, y] * 0.88 and b - r < 30 and b - g < 25:  # dark, and not blue
                M[x, y] = 0
                cells.add((int(x * k / 2) * 2, int(y * k / 2) * 2))
    mask.save(os.path.join(here, "out", f"{name}-ink.png"))
    json.dump(sorted(cells), open(os.path.join(here, "out", f"{name}-ink.json"), "w"))
    print(name, len(cells), "ink cells")
