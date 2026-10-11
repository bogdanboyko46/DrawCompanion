# Contact sheet from pipeline result PNGs (6-panel sheets written by batch.py).
#   python sheet.py <results_dir> <out.jpg> <tag-substring> [more substrings...]
# One row per matching result: [traced strokes on the original photo | zoom].
import os, sys
from PIL import Image, ImageDraw, ImageFont

res_dir, out = sys.argv[1:3]
subs = sys.argv[3:]
files = sorted(f for f in os.listdir(res_dir) if f.endswith(".png") and all(s in f for s in subs))
W = 640
try:
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 15)
except OSError:
    font = ImageFont.load_default()
rows = []
for f in files:
    im = Image.open(os.path.join(res_dir, f))
    tw = (im.width - 20) // 3
    th = (im.height - 40) // 2
    full = im.crop((0, th + 5, tw, 2 * th + 5))
    zoom = im.crop((tw + 10, th + 5, 2 * tw + 10, 2 * th + 5))
    cap = im.crop((0, 2 * th + 5, im.width, im.height))
    full = full.resize((W, int(th * W / tw)), Image.LANCZOS)
    zoom = zoom.resize((W, int(th * W / tw)), Image.LANCZOS)
    cap = cap.resize((2 * W + 8, int(cap.height * (2 * W + 8) / cap.width)), Image.LANCZOS)
    row = Image.new("RGB", (2 * W + 8, full.height + cap.height + 22), "white")
    ImageDraw.Draw(row).text((4, 2), f[:-4], fill="black", font=font)
    row.paste(full, (0, 22)); row.paste(zoom, (W + 8, 22)); row.paste(cap, (0, 22 + full.height))
    rows.append(row)
sheet = Image.new("RGB", (2 * W + 8, sum(r.height + 8 for r in rows)), (210, 210, 210))
y = 0
for r in rows:
    sheet.paste(r, (0, y)); y += r.height + 8
sheet.save(out, quality=85)
print(out, len(rows), "rows")
