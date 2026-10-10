"""Synthetic "phone photos" of a drawing on a table, for the scanner tests.

Each photo has known paper corners, so the test can check detection,
rectification and white balance against ground truth.

  python3 ios/ScannerTests/make_fixtures.py
"""

import json
import math
import os
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "fixtures")
W, H = 1920, 1440  # 4:3, like ARKit's high-resolution frames
PAGE_W, PAGE_H = 1050, 1485  # A4 proportions


def drawing():
    """A kid-style character: marker outlines, crayon-ish fills, on white paper."""
    img = Image.new("RGB", (PAGE_W, PAGE_H), (250, 250, 247))
    d = ImageDraw.Draw(img)
    ink = (25, 25, 35)
    cx = PAGE_W // 2
    # body and head
    d.ellipse([cx - 230, 560, cx + 230, 1120], fill=(245, 140, 50), outline=ink, width=14)
    d.ellipse([cx - 200, 260, cx + 200, 640], fill=(245, 140, 50), outline=ink, width=14)
    # ears
    d.polygon([(cx - 170, 330), (cx - 120, 160), (cx - 60, 290)], fill=(245, 140, 50), outline=ink, width=12)
    d.polygon([(cx + 170, 330), (cx + 120, 160), (cx + 60, 290)], fill=(245, 140, 50), outline=ink, width=12)
    # belly, eyes, smile, cheeks
    d.ellipse([cx - 130, 720, cx + 130, 1060], fill=(255, 225, 160), outline=ink, width=8)
    for s in (-1, 1):
        d.ellipse([cx + s * 80 - 35, 400, cx + s * 80 + 35, 490], fill=ink)
        d.ellipse([cx + s * 80 - 12, 412, cx + s * 80 + 6, 432], fill=(255, 255, 255))
        d.ellipse([cx + s * 140 - 30, 510, cx + s * 140 + 30, 545], fill=(240, 110, 130))
    d.arc([cx - 60, 470, cx + 60, 570], 20, 160, fill=ink, width=10)
    # arms, legs, a blue scarf
    d.line([(cx - 220, 760), (cx - 380, 640)], fill=ink, width=16)
    d.line([(cx + 220, 760), (cx + 380, 640)], fill=ink, width=16)
    d.line([(cx - 110, 1100), (cx - 130, 1300)], fill=ink, width=16)
    d.line([(cx + 110, 1100), (cx + 130, 1300)], fill=ink, width=16)
    d.ellipse([cx - 190, 1280, cx - 70, 1340], fill=ink)
    d.ellipse([cx + 70, 1280, cx + 190, 1340], fill=ink)
    d.rounded_rectangle([cx - 190, 600, cx + 190, 680], radius=30, fill=(60, 110, 220), outline=ink, width=10)
    # a name written in the corner
    d.text((70, 1380), "PIP", fill=ink)
    # stray things that must NOT end up in the character: a sun doodle in the
    # corner and a scribble near the bottom edge
    d.ellipse([885, 65, 975, 155], outline=(240, 180, 40), width=8)
    for k in range(8):
        a = k * math.pi / 4
        d.line([(930 + 60 * math.cos(a), 110 + 60 * math.sin(a)), (930 + 80 * math.cos(a), 110 + 80 * math.sin(a))],
               fill=(240, 180, 40), width=6)
    d.line([(840, 1420), (900, 1395), (960, 1430), (1000, 1405)], fill=(90, 90, 100), width=5)
    return img


def table(seed):
    rng = np.random.default_rng(seed)
    y = np.arange(H)[:, None]
    x = np.arange(W)[None, :]
    grain = 0.5 + 0.5 * np.sin(x / 37.0 + 4 * np.sin(y / 230.0)) * np.sin(y / 9.0 + x / 400.0)
    base = np.stack([110 + 40 * grain, 72 + 25 * grain, 45 + 15 * grain], axis=-1)
    base += rng.normal(0, 4, base.shape)
    return np.clip(base, 0, 255)


def homography(src, dst):
    a = []
    for (x, y), (u, v) in zip(src, dst):
        a.append([-x, -y, -1, 0, 0, 0, u * x, u * y, u])
        a.append([0, 0, 0, -x, -y, -1, v * x, v * y, v])
    _, _, vt = np.linalg.svd(np.array(a))
    return vt[-1].reshape(3, 3) / vt[-1][-1]


def warp_onto(bg, page, corners):
    """Inverse-map every background pixel inside the quad back to the page."""
    hinv = homography(corners, [(0, 0), (PAGE_W, 0), (PAGE_W, PAGE_H), (0, PAGE_H)])
    ys, xs = np.mgrid[0:H, 0:W]
    pts = np.stack([xs.ravel(), ys.ravel(), np.ones(xs.size)])
    m = hinv @ pts
    u, v = m[0] / m[2], m[1] / m[2]
    inside = (u >= 0) & (u < PAGE_W - 1) & (v >= 0) & (v < PAGE_H - 1)
    src = np.asarray(page, dtype=np.float64)
    # bilinear sample
    u0, v0 = np.floor(u[inside]).astype(int), np.floor(v[inside]).astype(int)
    fu, fv = (u[inside] - u0)[:, None], (v[inside] - v0)[:, None]
    s = (src[v0, u0] * (1 - fu) * (1 - fv) + src[v0, u0 + 1] * fu * (1 - fv)
         + src[v0 + 1, u0] * (1 - fu) * fv + src[v0 + 1, u0 + 1] * fu * fv)
    out = bg.reshape(-1, 3).copy()
    out[inside] = s
    return out.reshape(H, W, 3)


def photo(name, corners, tint, seed, page=True):
    bg = table(seed)
    if page:
        # soft drop shadow under the paper
        shadow = Image.new("L", (W, H), 0)
        ImageDraw.Draw(shadow).polygon([(x + 14, y + 18) for x, y in corners], fill=110)
        shadow = np.asarray(shadow.filter(ImageFilter.GaussianBlur(18)), dtype=np.float64)[..., None] / 255
        bg = bg * (1 - 0.6 * shadow)
        img = warp_onto(bg, drawing(), corners)
    else:
        img = bg
    # lamp: warm tint plus a falloff from one corner
    ys, xs = np.mgrid[0:H, 0:W]
    falloff = 1 - 0.25 * np.hypot(xs - W * 0.2, ys - H * 0.1) / np.hypot(W, H)
    img = img * np.array(tint)[None, None, :] * falloff[..., None]
    img += np.random.default_rng(seed + 1).normal(0, 2.5, img.shape)
    Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).save(os.path.join(OUT, f"{name}.jpg"), quality=90)
    return {"file": f"{name}.jpg", "page": page, "corners": corners if page else None, "tint": tint}


def main():
    os.makedirs(OUT, exist_ok=True)
    random.seed(1)
    cases = [
        # straight-ish from above, neutral light
        photo("overhead", [(560, 180), (1360, 210), (1390, 1290), (520, 1260)], (1.0, 1.0, 1.0), 1),
        # held at an angle: strong perspective, warm lamp
        photo("angled-warm", [(690, 260), (1250, 250), (1520, 1300), (380, 1320)], (1.0, 0.88, 0.70), 2),
        # page turned ~90° on the desk: its top edge faces the right of the photo
        photo("turned", [(1600, 300), (1640, 1150), (450, 1190), (420, 330)], (0.97, 0.95, 0.9), 3),
        # no paper at all
        photo("no-page", None, (1.0, 0.95, 0.85), 4, page=False),
    ]
    with open(os.path.join(OUT, "cases.json"), "w") as f:
        json.dump({"pageSize": [PAGE_W, PAGE_H], "cases": cases}, f, indent=2)
    drawing().save(os.path.join(OUT, "drawing-original.png"))
    print("wrote", [c["file"] for c in cases])


if __name__ == "__main__":
    main()
