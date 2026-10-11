# Ground-truth test of the registration: re-render each page photo with a KNOWN
# transform (scale, rotation, shift, mild perspective, letterbox padding, JPEG), with
# and without a local warp of the drawing, and check (a) the recovered transform
# against the truth, in paper units, at the drawing's own pixels, and (b) that local
# warps are rejected.
#   python synth.py [trials-per-page]
import io, json, math, os, sys, time
import numpy as np
import cv2
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from register import register, apply_h

here = os.path.dirname(os.path.abspath(__file__))
rng = np.random.default_rng(7)


def random_h(w, h, out=1024):
    s = out / w * rng.uniform(0.75, 1.0)
    a = math.radians(rng.uniform(-3, 3))
    asp = rng.uniform(0.94, 1.06)                    # generators squash the page a little
    A = np.array([[s * math.cos(a), -s * math.sin(a)], [s * math.sin(a), s * math.cos(a)]]) @ np.diag([1, asp])
    c = A @ np.array([w / 2, h / 2])
    t = np.array([out / 2, out / 2]) - c + rng.uniform(-40, 40, 2)
    H = np.eye(3); H[:2, :2] = A; H[:2, 2] = t
    H[2, :2] = rng.uniform(-2e-5, 2e-5, 2)           # a hint of perspective
    return H


def local_warp(img, cx, cy, radius, amp, mode):
    """Displace pixels near (cx, cy): 'stretch' scales the region, 'shift' moves it."""
    h, w = img.shape[:2]
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    dx, dy = xx - cx, yy - cy
    r = np.sqrt(dx * dx + dy * dy)
    fall = np.exp(-(r / radius) ** 2)
    if mode == "stretch":                            # like nano-banana enlarging the figure
        k = amp / radius
        mx, my = xx - k * dx * fall, yy - k * dy * fall
    else:
        mx, my = xx - amp * fall, yy - 0.5 * amp * fall
    return cv2.remap(img, mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)


def render(orig, H, out=1024):
    g = cv2.warpPerspective(orig, H, (out, out), flags=cv2.INTER_LINEAR, borderValue=(235, 235, 235))
    buf = io.BytesIO()
    Image.fromarray(g).save(buf, "JPEG", quality=80)
    return np.asarray(Image.open(buf).convert("RGB"))


trials = int(sys.argv[1]) if len(sys.argv) > 1 else 6
rows = []
for page in ("page-1", "page-2", "page-3"):
    orig = np.asarray(Image.open(os.path.join(here, "..", "photos", f"{page}.jpg")).convert("RGB"))
    h, w = orig.shape[:2]
    units = 1000.0 / w
    for t in range(trials):
        H = random_h(w, h)
        for warp in ("none", "shift3", "shift6", "stretch6", "stretch12"):
            src = orig
            if warp != "none":
                # warp around the figure's head (where the ink is) in ORIGINAL px
                ys, xs = np.nonzero(cv2.cvtColor(orig, cv2.COLOR_RGB2GRAY) < 140)
                cx, cy = 450 / units, 130 / units
                amp = float(warp[-1] if warp[-2].isalpha() else warp[-2:]) / units
                src = local_warp(orig, cx, cy, 70 / units, amp, "shift" if warp.startswith("shift") else "stretch")
            g = render(src, H)
            t0 = time.time()
            r = register(orig, g)
            ms = (time.time() - t0) * 1000
            # true error: map original ink points with the recovered H and with the truth
            P = r["P"]
            err = np.hypot(*(apply_h(r["H"], P) - apply_h(H, P)).T)
            s = math.sqrt(abs(np.linalg.det(H[:2, :2])))
            err_u = err / s * units
            st = r["stats"]
            rows.append({"page": page, "trial": t, "warp": warp, "accept": st["accept"],
                         "true_err_median": float(np.median(err_u)), "true_err_max": float(err_u.max()),
                         "resid_median": st["median"], "resid_p90": st["p90"], "cover3": st["cover3"],
                         "worst_part": st["worst_part_median"], "worst_shift": st["worst_part_shift"], "ms": ms})
            print(json.dumps({k: (round(v, 2) if isinstance(v, float) else v) for k, v in rows[-1].items()}))

json.dump(rows, open(os.path.join(here, "results", "synth.json"), "w"), indent=1)
none = [r for r in rows if r["warp"] == "none"]
print("\nclean re-renders:", len(none), "accepted", sum(r["accept"] for r in none), "worst_shift", sorted(round(r["worst_shift"], 2) for r in none),
      "true error median %.2f u, worst max %.2f u" % (np.median([r["true_err_median"] for r in none]),
                                                      max(r["true_err_max"] for r in none)))
for wv in ("shift3", "shift6", "stretch6", "stretch12"):
    sel = [r for r in rows if r["warp"] == wv]
    print(wv, "rejected", sum(not r["accept"] for r in sel), "/", len(sel), "true err median %.2f" % np.median([r["true_err_median"] for r in sel]), "worst_shift", sorted(round(r["worst_shift"], 2) for r in sel))
print("register ms median", np.median([r["ms"] for r in rows]))
