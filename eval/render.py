# Draws each case's outline onto its page photo, for checking the scores by eye.
#   python3 eval/render.py <label>      (reads eval/results/<label>.json)
# Writes eval/results/<label>/<case>.png and a contact sheet eval/results/<label>.png.
# Red: the new outline (orange: construction lines). Green box: where it should go.
# Grey dashed: the shown outline being revised. Blue: the model's own "place" box.
import json, math, os, sys
from PIL import Image, ImageDraw, ImageFont

here = os.path.dirname(os.path.abspath(__file__))
label = sys.argv[1]
data = json.load(open(os.path.join(here, "results", f"{label}.json")))
cases = json.load(open(os.path.join(here, "cases.json")))
spec = {c["id"]: c for c in cases["draw"]}
out_dir = os.path.join(here, "results", label)
os.makedirs(out_dir, exist_ok=True)
try:
    font = ImageFont.truetype("DejaVuSans.ttf", 13)
except OSError:
    font = ImageFont.load_default()

tiles = []
for r in data["results"]:
    if "strokes" not in r:
        continue
    page = cases["pages"][r["page"]]
    im = Image.open(os.path.join(here, page["photo"])).convert("RGB")
    scale = 2
    im = im.resize((im.width * scale, im.height * scale), Image.LANCZOS)
    k = im.width / page["paper"]["w"]
    d = ImageDraw.Draw(im)
    c = spec.get(r["id"], {})
    for t in c.get("target", []):
        d.rectangle([v * k for v in t], outline=(0, 170, 0), width=2)
    for s in r.get("current") or []:
        pts = [(p["x"] * k, p["y"] * k) for p in s["points"]]
        for i in range(0, len(pts) - 1, 2):
            d.line(pts[i:i + 2], fill=(120, 120, 120), width=2)
    place = (r.get("plan") or {}).get("place")
    if place and place.get("box"):
        b = place["box"]
        d.rectangle([b["x0"] * k, b["y0"] * k, b["x1"] * k, b["y1"] * k], outline=(40, 90, 255), width=1)
    for s in r["strokes"]:
        pts = [(p["x"] * k, p["y"] * k) for p in s["points"]]
        if s.get("closed"):
            pts.append(pts[0])
        d.line(pts, fill=(255, 150, 0) if s["role"] == "construction" else (225, 0, 0), width=3)
    verdict = "PASS" if r["pass"] else f"fail: {r['why']}"
    caption = f"{r['id']} #{r['run']}  {verdict}  first stroke {r['ms']['firstStroke']} ms"
    d.rectangle([0, im.height - 40, im.width, im.height], fill=(255, 255, 255))
    d.text((6, im.height - 38), caption, fill=(0, 0, 0), font=font)
    d.text((6, im.height - 20), " / ".join(r["said"])[:110], fill=(60, 60, 60), font=font)
    file = os.path.join(out_dir, f"{r['id']}-{r['run']}.png")
    im.save(file)
    tiles.append(im.resize((im.width // 2, im.height // 2), Image.LANCZOS))

if tiles:
    cols = 3
    w = max(t.width for t in tiles); h = max(t.height for t in tiles)
    sheet = Image.new("RGB", (cols * w, math.ceil(len(tiles) / cols) * h), (255, 255, 255))
    for i, t in enumerate(tiles):
        sheet.paste(t, ((i % cols) * w, (i // cols) * h))
    sheet.save(os.path.join(here, "results", f"{label}.png"))
    print(f"{len(tiles)} overlays in eval/results/{label}/, sheet eval/results/{label}.png")
