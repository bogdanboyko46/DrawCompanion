# Where the processing time goes (Python/OpenCV on a laptop; see README for the
# on-device estimate).   python profile.py <original.jpg> <generated.png>
import os, sys, time
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import register as R
import ink
import pipeline

o = np.asarray(Image.open(sys.argv[1]).convert("RGB"))
g = np.asarray(Image.open(sys.argv[2]).convert("RGB"))
T = {}


def tm(name, f, *a, **k):
    t = time.perf_counter()
    r = f(*a, **k)
    T[name] = T.get(name, 0) + (time.perf_counter() - t) * 1000
    return r


om, _, _ = tm("ink mask original", ink.ink_mask, o, 3.0, border=6)
gl = 3.0 * g.shape[1] / o.shape[1]
gm, _, _ = tm("ink mask generated", ink.ink_mask, g, gl)
_, P = tm("skeleton original", R.skel_points, om)
gsk, _ = tm("skeleton generated", R.skel_points, gm)
tm("distance transform", R.nearest_lookup, gsk)
c = tm("coarse search (3 aspects x 36 scales)", R.coarse, om, gm, 3.0, gl)
tm("register() total", R.register, o, g)
tm("pipeline total", pipeline.process, sys.argv[1], sys.argv[2])
for k, v in T.items():
    print(f"{k:40s} {v:7.0f} ms")
