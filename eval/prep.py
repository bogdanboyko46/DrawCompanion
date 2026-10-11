# Makes the close-up photos the app would send, from the full page photos:
# the drawing's box with margins (same rule as Core/PageRegion.swift), cropped,
# enlarged to WIDTH pixels, with a faint grid labeled in page units every STEP.
#   python3 eval/prep.py [width=900] [step=50] [margin=0.4]
# margin: room around the drawing, as a fraction of its larger side (the app uses 0.4).
# Writes eval/out/<page>-closeup-<width>-<step>-<margin>.jpg and eval/out/regions.json.
# The eval photos are only 768 px wide (the phone crops from a 1600 px page),
# so these close-ups are softer than the phone's; positions are the same.
import json, os, sys
from PIL import Image, ImageDraw, ImageFont

here = os.path.dirname(os.path.abspath(__file__))
width = int(sys.argv[1]) if len(sys.argv) > 1 else 900
step = int(sys.argv[2]) if len(sys.argv) > 2 else 50
margin = float(sys.argv[3]) if len(sys.argv) > 3 else 0.4
cases = json.load(open(os.path.join(here, "cases.json")))
os.makedirs(os.path.join(here, "out"), exist_ok=True)
regions_path = os.path.join(here, "out", "regions.json")
regions = json.load(open(regions_path)) if os.path.exists(regions_path) else {}

def focus(parts, paper):
    x0 = min(b[0] for b in parts.values()); y0 = min(b[1] for b in parts.values())
    x1 = max(b[2] for b in parts.values()); y1 = max(b[3] for b in parts.values())
    x, y, w, h = x0, y0, x1 - x0, y1 - y0
    m = max(w, h) * margin + 30
    x, y, w, h = x - m, y - m, w + 2 * m, h + 2 * m
    if w < 300: x -= (300 - w) / 2; w = 300
    if h < 300: y -= (300 - h) / 2; h = 300
    x, y = max(0, x), max(0, y)
    w, h = min(paper["w"] - x, w), min(paper["h"] - y, h)
    return {"x": x, "y": y, "w": w, "h": h}

try:
    font = ImageFont.truetype("DejaVuSans.ttf", 12)
except OSError:
    font = ImageFont.load_default()

for name, page in cases["pages"].items():
    paper = page["paper"]
    r = focus(page["parts"], paper)
    im = Image.open(os.path.join(here, page["photo"])).convert("RGB")
    k = im.width / paper["w"]
    crop = im.crop((round(r["x"] * k), round(r["y"] * k), round((r["x"] + r["w"]) * k), round((r["y"] + r["h"]) * k)))
    height = round(width * r["h"] / r["w"])
    out = crop.resize((width, height), Image.LANCZOS)
    d = ImageDraw.Draw(out, "RGBA")
    px = width / r["w"]
    u = (int(r["x"]) // step + 1) * step
    while u < r["x"] + r["w"]:
        x = (u - r["x"]) * px
        d.line([(x, 0), (x, height)], fill=(0, 150, 255, 77), width=1)
        d.text((x + 2, 1), str(u), fill=(0, 120, 219, 217), font=font)
        u += step
    v = (int(r["y"]) // step + 1) * step
    while v < r["y"] + r["h"]:
        y = (v - r["y"]) * px
        d.line([(0, y), (width, y)], fill=(0, 150, 255, 77), width=1)
        d.text((2, y - 15), str(v), fill=(0, 120, 219, 217), font=font)
        v += step
    file = f"{name}-closeup-{width}-{step}-{margin:g}.jpg"
    out.save(os.path.join(here, "out", file), quality=85)
    regions[file] = r
    print(name, {k2: round(v2) for k2, v2 in r.items()}, file)
json.dump(regions, open(regions_path, "w"), indent=1)
