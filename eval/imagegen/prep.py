# Photo variants to send to the image model.
#   python prep.py <photo.jpg> <out_prefix>
# Writes <out_prefix>-nogrid.jpg  (blue grid + labels inpainted away)
#        <out_prefix>-clean.jpg   (no grid, and the lighting flattened to white paper:
#                                  a "scan" of the page; pencil kept as grey)
import sys, os
import numpy as np
import cv2
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ink import paper_bg, ink_score


def grid_mask(rgb, line_px=3.0):
    img = rgb.astype(np.float32)
    n = np.clip(img / paper_bg(img, line_px), 0, 1.2)
    blue = ((n[..., 2] - n[..., 0]) > 0.08) & ((1 - n[..., 0]) > 0.08)
    return cv2.dilate(blue.astype(np.uint8), np.ones((3, 3), np.uint8)) > 0


def nogrid(rgb):
    """Inpaint the blue grid and labels, but not where pencil crosses them."""
    s = ink_score(rgb, 3.0)
    pencil = s > 0.10
    g = grid_mask(rgb)
    g = cv2.dilate(g.astype(np.uint8), np.ones((3, 3), np.uint8)) > 0
    bg = paper_bg(rgb.astype(np.float32), 3.0)      # the closing has no grid lines in it
    out = rgb.copy()
    m = g & ~pencil
    out[m] = bg[m].astype(np.uint8)
    # pencil pixels on a grid line keep a blue cast: make them neutral grey
    on = g & pencil
    out[on] = out[on].min(axis=1, keepdims=True)
    return out


def clean(rgb):
    """A 'scan' of the page: white paper, neutral grey pencil, no grid, no shadow."""
    s = ink_score(rgb, 3.0)
    s = np.clip(s - 0.06, 0, 1)                      # paper texture -> pure white
    v = 1.0 - np.clip(s * 2.2, 0, 0.8)
    v = cv2.GaussianBlur(v, (0, 0), 0.6)
    out = (v * 248).astype(np.uint8)
    return np.dstack([out, out, out])


if __name__ == "__main__":
    src, prefix = sys.argv[1:3]
    rgb = np.asarray(Image.open(src).convert("RGB"))
    Image.fromarray(nogrid(rgb)).save(prefix + "-nogrid.jpg", quality=92)
    Image.fromarray(clean(rgb)).save(prefix + "-clean.jpg", quality=92)
