# Draws returned strokes (paper units) in red onto the full page photo.
import sys, json
from PIL import Image, ImageDraw
src, out, pw = sys.argv[1], sys.argv[2], float(sys.argv[3])
strokes = json.load(open(sys.argv[4]))
im = Image.open(src).convert("RGB")
k = im.width / pw
d = ImageDraw.Draw(im)
for st in strokes:
    pts = [(x * k, y * k) for x, y in st["points"]]
    if st["closed"]: pts.append(pts[0])
    d.line(pts, fill=(230, 0, 0) if st["role"] != "construction" else (255, 150, 0), width=2)
im.crop((150, 0, 500, 230)).resize((700, 460)).save(out)
