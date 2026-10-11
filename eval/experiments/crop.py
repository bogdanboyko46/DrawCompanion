# Makes the "zoomed" variant: crop around the drawing, upscale, finer grid labeled in page units.
import sys
from PIL import Image, ImageDraw, ImageFont
src, out, x0, y0, x1, y1, pw, ph = sys.argv[1], sys.argv[2], *map(float, sys.argv[3:9])
im = Image.open(src).convert("RGB")
k = im.width / pw  # px per paper unit in the source
crop = im.crop((round(x0*k), round(y0*k), round(x1*k), round(y1*k)))
W = 900
s = W / crop.width
crop = crop.resize((W, round(crop.height * s)), Image.LANCZOS)
d = ImageDraw.Draw(crop)
try:
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 13)
except Exception:
    font = ImageFont.load_default()
u = lambda v, o: (v - o) * k * s
for v in range(int(x0 // 50 + 1) * 50, int(x1), 50):
    d.line([(u(v, x0), 0), (u(v, x0), crop.height)], fill=(0, 150, 255), width=1)
    d.text((u(v, x0) + 2, 2), str(v), fill=(0, 110, 220), font=font)
for v in range(int(y0 // 50 + 1) * 50, int(y1), 50):
    d.line([(0, u(v, y0)), (W, u(v, y0))], fill=(0, 150, 255), width=1)
    d.text((2, u(v, y0) - 15), str(v), fill=(0, 110, 220), font=font)
crop.save(out, quality=88)
print(crop.size)
