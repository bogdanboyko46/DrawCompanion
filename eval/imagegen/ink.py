# Ink detection shared by the registration, extraction and tracing steps.
#
# Pencil is close to neutral grey; the baked-in grid and its labels are saturated
# blue; the shadow is a broad blue tint. We divide each channel by a local paper
# estimate (a grey closing, so thin dark lines are removed from the estimate) and
# take darkness in the BLUE channel: blue ink reflects blue, so the grid barely
# darkens it, while graphite darkens every channel. A chroma penalty removes what
# is left of the grid where it is anti-aliased.
import numpy as np
import cv2


def paper_bg(img, line_px):
    """Per-channel local paper colour. line_px: rough max stroke width in px."""
    k = int(line_px * 3) | 1
    ker = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))
    bg = cv2.morphologyEx(img, cv2.MORPH_CLOSE, ker)
    bg = cv2.GaussianBlur(bg, (0, 0), line_px * 1.5)
    return np.maximum(bg, 1.0)


def ink_score(rgb, line_px=3.0, bg=None):
    """rgb uint8 HxWx3 -> float32 HxW in [0,1], ~0 on paper/grid, ~0.15-0.7 on pencil."""
    img = rgb.astype(np.float32)
    if bg is None:
        bg = paper_bg(img, line_px)
    # The grid lines are part of the "background" a pencil mark sits on. A closing
    # along each axis (61 px) keeps the grid line but removes anything that crosses
    # it or runs beside it for less than 61 px. Where that estimate is a bluish line,
    # it replaces the paper estimate, so pencil ON a grid line is measured against
    # the grid's colour and stays visible, and the grid itself (and its JPEG chroma
    # fringes, which run along it too) cancels out.
    exp = bg.copy()
    on_grid = np.zeros(img.shape[:2], bool)
    L = int(line_px * 15) | 1
    for ker in (np.ones((1, L), np.uint8), np.ones((L, 1), np.uint8)):
        c = cv2.morphologyEx(img, cv2.MORPH_CLOSE, ker)
        nc = c / bg
        gridish = ((nc[..., 2] - nc[..., 0]) > 0.04) & (nc.mean(axis=2) < 0.985) & (nc[..., 2] > 0.62)
        exp = np.where(gridish[..., None], np.minimum(exp, c), exp)
        on_grid |= gridish
    exp = np.maximum(exp, 1.0)
    nb = np.clip(img[..., 2] / exp[..., 2], 0, 1.2)
    dark_b = 1.0 - nb                              # graphite darkens blue, blue ink does not
    # blue ink that is NOT a grid line (the printed labels): penalise by its blueness
    n0 = img / bg
    blueness = np.maximum(0.0, (n0[..., 2] - n0[..., 0]) - 0.12) * (~on_grid)
    # coloured (red) ink is not pencil either; see red_score() for that
    redness = np.maximum(0.0, (n0[..., 0] - n0[..., 2]) - 0.12)
    s = dark_b - 2.0 * blueness - 2.0 * redness
    return np.clip(s, 0, 1).astype(np.float32)


def red_score(rgb, line_px=3.0):
    """Red-pen ink (the colour-coded variant: the model draws ONLY the new object in
    red). Red ink keeps the red channel and darkens green/blue."""
    img = rgb.astype(np.float32)
    bg = paper_bg(img, line_px)
    n = np.clip(img / bg, 0, 1.2)
    s = n[..., 0] - 0.5 * (n[..., 1] + n[..., 2])          # ~0 on paper, grey and blue
    return np.clip(s, 0, 1).astype(np.float32)


def red_mask(rgb, line_px=3.0, hi=0.22, lo=0.12, min_area=None):
    s = red_score(rgb, line_px)
    strong = (s >= hi).astype(np.uint8)
    weak = (s >= lo).astype(np.uint8)
    n, lab, stats, _ = cv2.connectedComponentsWithStats(weak, connectivity=8)
    keep = np.zeros(n, bool)
    keep[np.unique(lab[strong > 0])] = True
    keep[0] = False
    if min_area is None:
        min_area = int(line_px * line_px * 3)
    keep &= stats[:, cv2.CC_STAT_AREA] >= min_area
    return keep[lab], s


def page_mask(rgb, line_px=3.0, border=0, erode=None):
    """Where the paper is (not the dark table / black wedge at the photo edge).
    border: px to ignore along the image edges (the page photos are cropped to the
    sheet, so their own edge shows as a dark line)."""
    img = rgb.astype(np.float32)
    bg = paper_bg(img, line_px)
    lum = bg.mean(axis=2)
    ok = lum > 0.6 * np.median(lum)
    if border:
        ok[:border] = ok[-border:] = False
        ok[:, :border] = ok[:, -border:] = False
    k = int(line_px * 5) | 1 if erode is None else int(erode) | 1
    ok = cv2.erode(ok.astype(np.uint8), np.ones((k, k), np.uint8))
    return ok > 0, bg


def ink_mask(rgb, line_px=3.0, rel=0.42, floor=0.12, min_area=None, border=0):
    """Hysteresis threshold of ink_score relative to the image's own ink contrast,
    restricted to the paper, tiny components (speckles) dropped."""
    ok, bg = page_mask(rgb, line_px, border)
    s = ink_score(rgb, line_px, bg) * ok
    p = float(np.percentile(s[ok], 99.9)) if ok.any() else 0.3
    hi = min(max(floor, rel * p), 0.2)
    lo = 0.6 * hi
    strong = (s >= hi).astype(np.uint8)
    weak = (s >= lo).astype(np.uint8)
    n, lab, stats, _ = cv2.connectedComponentsWithStats(weak, connectivity=8)
    keep = np.zeros(n, bool)
    keep[np.unique(lab[strong > 0])] = True
    keep[0] = False
    if min_area is None:
        min_area = int(line_px * line_px * 3)
    keep &= stats[:, cv2.CC_STAT_AREA] >= min_area
    return keep[lab], s, ok
