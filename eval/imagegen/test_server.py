# End-to-end test of server.py: posts eval cases, renders returned strokes on the photo.
#   python test_server.py <out_dir> [url] [case ...]
# Cases use Claude-like outline boxes inside the eval/cases.json targets.
import base64, json, os, re, sys, time, urllib.request
import concurrent.futures as cf
from PIL import Image, ImageDraw

here = os.path.dirname(os.path.abspath(__file__))
CASES = {
    "cat":   ("page-2", ["can you draw a cat next to him"], {"x0": 70, "y0": 150, "x1": 260, "y1": 330}),
    "house": ("page-1", ["draw a house on the right side of the page"], {"x0": 650, "y0": 90, "x1": 930, "y1": 380}),
    "hat":   ("page-3", ["give him a hat"], {"x0": 385, "y0": 20, "x1": 535, "y1": 95}),
    "tree":  ("page-3", ["I'm stuck", "maybe a tree to the left of him?"], {"x0": 60, "y0": 40, "x1": 290, "y1": 420}),
}


def parse_d(d):
    toks = re.findall(r"[MCZ]|-?\d+(?:\.\d+)?", d)
    pts, i, cur, start = [], 0, None, None
    while i < len(toks):
        t = toks[i]
        if t == "M":
            cur = (float(toks[i + 1]), float(toks[i + 2])); start = cur; pts.append(cur); i += 3
        elif t == "C":
            c = [float(v) for v in toks[i + 1:i + 7]]
            p0, p1, p2, p3 = cur, (c[0], c[1]), (c[2], c[3]), (c[4], c[5])
            for k in range(1, 13):
                s = k / 12; m = 1 - s
                pts.append((m**3*p0[0] + 3*m*m*s*p1[0] + 3*m*s*s*p2[0] + s**3*p3[0],
                            m**3*p0[1] + 3*m*m*s*p1[1] + 3*m*s*s*p2[1] + s**3*p3[1]))
            cur = p3; i += 7
        elif t == "Z":
            pts.append(start); i += 1
        else:
            i += 1
    return pts


def run(name, url, out_dir):
    page, said, box = CASES[name]
    photo = os.path.join(here, "..", "photos", f"{page}.jpg")
    im = Image.open(photo)
    body = {"page_jpeg": base64.b64encode(open(photo, "rb").read()).decode(),
            "paper": {"w": 1000, "h": round(im.height * 1000 / im.width)}, "said": said, "box": box, "id": f"test-{name}"}
    t = time.time()
    req = urllib.request.Request(url + "/upgrade", data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    resp = json.loads(urllib.request.urlopen(req, timeout=60).read())
    wall = time.time() - t
    json.dump(resp, open(os.path.join(out_dir, f"{name}.json"), "w"), indent=1)
    big = im.convert("RGB").resize((im.width * 2, im.height * 2), Image.LANCZOS)
    d = ImageDraw.Draw(big)
    k = big.width / 1000
    d.rectangle([box["x0"] * k, box["y0"] * k, box["x1"] * k, box["y1"] * k], outline=(0, 170, 0), width=2)
    for s in resp.get("strokes", []):
        d.line([(x * k, y * k) for x, y in parse_d(s["d"])], fill=(225, 0, 0) if s["role"] == "contour" else (255, 120, 0), width=3)
    d.text((6, 6), f"{name}: ok={resp['ok']} wall {wall:.1f}s {resp.get('reason', '')}"[:150], fill=(0, 0, 0))
    big.save(os.path.join(out_dir, f"{name}.png"))
    return name, wall, resp


if __name__ == "__main__":
    out_dir = sys.argv[1]
    url = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:8787"
    names = sys.argv[3:] or list(CASES)
    os.makedirs(out_dir, exist_ok=True)
    with cf.ThreadPoolExecutor(len(names)) as ex:
        for name, wall, resp in ex.map(lambda n: run(n, url, out_dir), names):
            print(name, f"wall {wall:.1f}s", "ok" if resp["ok"] else "REJECT " + resp.get("reason", ""),
                  json.dumps(resp.get("ms")), len(resp.get("strokes", [])), "strokes", resp.get("new_box"))
