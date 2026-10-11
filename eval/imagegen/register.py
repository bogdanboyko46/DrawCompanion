# Registration of a generated image (any size, padded / letterboxed / scaled /
# shifted / slightly rotated) back onto the original page photo, using only the
# user's own pencil lines, which appear in both.
#
#   1. Ink masks of both images (ink.py), thinned to 1-px skeletons.
#   2. Coarse: for ~60 scales, normalized cross-correlation (FFT) of the blurred
#      original-ink patch against the blurred generated ink. Best (scale, x, y).
#   3. Fine: trimmed ICP, original skeleton -> nearest generated skeleton pixel
#      (distance transform with labels gives nearest-pixel lookup in O(1)),
#      similarity -> affine -> homography, with the inlier gate shrinking
#      from 12 to 2.5 paper units. New ink in the generated image is simply an
#      outlier: only original->generated distances are ever used.
#   4. Verification: residual of every original skeleton point (paper units),
#      coverage (share of original line within 3 units of generated ink), and
#      per-part residuals (each connected part of the original drawing). A model
#      that redrew or stretched the figure fails these and is rejected.
import numpy as np
import cv2
from skimage.morphology import skeletonize

from ink import ink_mask


def skel_points(mask):
    sk = skeletonize(mask)
    ys, xs = np.nonzero(sk)
    return sk, np.stack([xs, ys], 1).astype(np.float64)


def nearest_lookup(sk):
    """For every pixel: distance to and coordinates of the nearest skeleton pixel."""
    inv = (~sk).astype(np.uint8)
    dist, lab = cv2.distanceTransformWithLabels(inv, cv2.DIST_L2, 5, labelType=cv2.DIST_LABEL_PIXEL)
    ys, xs = np.nonzero(inv == 0)
    # labels are assigned to zero pixels in raster order
    coords = np.zeros((lab.max() + 1, 2), np.float64)
    coords[lab[ys, xs]] = np.stack([xs, ys], 1)
    return dist, lab, coords


def apply_h(H, P):
    q = np.c_[P, np.ones(len(P))] @ H.T
    return q[:, :2] / q[:, 2:3]


def jac(H, x, y):
    w = H[2, 0] * x + H[2, 1] * y + H[2, 2]
    u = (H[0, 0] * x + H[0, 1] * y + H[0, 2]) / w
    v = (H[1, 0] * x + H[1, 1] * y + H[1, 2]) / w
    return np.array([[H[0, 0] - u * H[2, 0], H[0, 1] - u * H[2, 1]],
                     [H[1, 0] - v * H[2, 0], H[1, 1] - v * H[2, 1]]]) / w


def plausible(H, box, max_aniso=1.2, max_persp=1.08):
    """A page photo re-rendered by an image model: near-similarity, little perspective.
    Guards against the chamfer degeneracies (collapse onto a dense patch, shear)."""
    x0, y0, x1, y1 = box
    scales = []
    for x, y in [(x0, y0), (x1, y0), (x0, y1), (x1, y1), ((x0 + x1) / 2, (y0 + y1) / 2)]:
        J = jac(H, x, y)
        if np.linalg.det(J) <= 0:
            return False
        sv = np.linalg.svd(J, compute_uv=False)
        if sv[0] / sv[1] > max_aniso:
            return False
        scales.append(np.sqrt(sv[0] * sv[1]))
    return max(scales) / min(scales) <= max_persp


def fit(model, P, Q, w=None):
    if model == "similarity":
        if True:
            # closed-form weighted similarity (Umeyama)
            w = np.ones(len(P)) if w is None else w
            ws = w / w.sum()
            mp, mq = (ws[:, None] * P).sum(0), (ws[:, None] * Q).sum(0)
            a, b = P - mp, Q - mq
            C = (ws[:, None, None] * (b[:, :, None] * a[:, None, :])).sum(0)
            U, S, Vt = np.linalg.svd(C)
            D = np.eye(2)
            if np.linalg.det(U @ Vt) < 0:
                D[1, 1] = -1
            R = U @ D @ Vt
            s = (S * np.diag(D)).sum() / (ws * (a ** 2).sum(1)).sum()
            t = mq - s * R @ mp
            M = np.c_[s * R, t]
        return np.vstack([M, [0, 0, 1]])
    if model == "affine":
        A = np.c_[P, np.ones(len(P))]
        X, *_ = np.linalg.lstsq(A, Q, rcond=None)
        return np.vstack([X.T, [0, 0, 1]])
    if model == "homography":
        H, _ = cv2.findHomography(P, Q, 0)
        return H
    raise ValueError(model)


def coarse(o_mask, g_mask, o_line, g_line, top=6):
    """Scale + translation search with FFT normalized cross-correlation."""
    ys, xs = np.nonzero(o_mask)
    pad = 12
    x0, x1 = max(xs.min() - pad, 0), min(xs.max() + pad, o_mask.shape[1])
    y0, y1 = max(ys.min() - pad, 0), min(ys.max() + pad, o_mask.shape[0])
    tmpl0 = cv2.GaussianBlur(o_mask[y0:y1, x0:x1].astype(np.float32), (0, 0), 2.0)
    # work at a reduced resolution of the generated image for speed
    r = 320.0 / max(g_mask.shape)
    gsmall = cv2.resize(g_mask.astype(np.float32), None, fx=r, fy=r, interpolation=cv2.INTER_AREA)
    gsmall = cv2.GaussianBlur(gsmall, (0, 0), 2.0 * r * g_line / o_line)
    cands = []
    base = g_mask.shape[1] / o_mask.shape[1]
    for aspect in (0.92, 1.0, 1.08):          # generators may squash the page a little
        for s in np.exp(np.linspace(np.log(0.4), np.log(2.5), 36)) * base:
            kx, ky = s * r, s * aspect * r
            tw, th = int(round(tmpl0.shape[1] * kx)), int(round(tmpl0.shape[0] * ky))
            if tw < 8 or th < 8 or tw >= gsmall.shape[1] or th >= gsmall.shape[0]:
                continue
            t = cv2.resize(tmpl0, (tw, th), interpolation=cv2.INTER_AREA)
            res = cv2.matchTemplate(gsmall, t, cv2.TM_CCORR_NORMED)
            _, v, _, loc = cv2.minMaxLoc(res)
            H = np.array([[s, 0, loc[0] / r - x0 * s], [0, s * aspect, loc[1] / r - y0 * s * aspect], [0, 0, 1.0]])
            cands.append((v, H))
    cands.sort(key=lambda c: -c[0])
    # keep the best few that are not near-duplicates (centre of the drawing maps elsewhere)
    c0 = np.array([(x0 + x1) / 2, (y0 + y1) / 2, 1.0])
    out = []
    for v, H in cands:
        p = H @ c0
        if all(np.hypot(*(p[:2] - (H2 @ c0)[:2])) > 20 or abs(np.log(H[0, 0] / H2[0, 0])) > 0.15 for _, H2 in out):
            out.append((v, H))
        if len(out) == top:
            break
    return out


def verdict(du, P, o_mask, units, exclude=None, pshift=None, max_shift=1.5):
    """Residual statistics (paper units) and the accept/reject decision.
    exclude: bool per point -- original lines the request was ABOUT (e.g. the smile
    when adding teeth), which a model may legitimately redraw; they are reported but
    not held against the image."""
    keep = np.ones(len(P), bool) if exclude is None else ~exclude
    n, labo = cv2.connectedComponents(o_mask.astype(np.uint8), connectivity=8)
    pi = labo[P[:, 1].astype(int), P[:, 0].astype(int)]
    parts = []
    for k in range(1, n):
        sel = (pi == k)
        if sel.sum() < 25:
            continue
        edited = bool((~keep[sel]).mean() > 0.5)
        parts.append({"n": int(sel.sum()), "median": float(np.median(du[sel])),
                      "shift": float(pshift[sel][0]) if pshift is not None else None,
                      "cover3": float((du[sel] < 3).mean()), "edited": edited,
                      "cx": float(P[sel, 0].mean() * units), "cy": float(P[sel, 1].mean() * units)})
    d = du[keep] if keep.any() else du
    inl = d < 3
    stats = {
        "median": float(np.median(d)), "p90": float(np.percentile(d, 90)),
        "rms_inliers": float(np.sqrt((d[inl] ** 2).mean())) if inl.any() else None,
        "cover3": float(inl.mean()), "cover5": float((d < 5).mean()),
        "worst_part_median": max((q["median"] for q in parts if q["n"] >= 40 and not q["edited"]), default=None),
        "worst_part_shift": max((q["shift"] for q in parts if q["n"] >= 40 and not q["edited"] and q["shift"] is not None), default=None),
        "edited_parts": sum(q["edited"] for q in parts),
        "parts": parts, "n_points": int(len(P)),
    }
    # accept: the drawing as a whole sits within 1.5 units, 80% of it within 3 units,
    # no part of it is more than 3 units off on median, and no part (an ear, a leg,
    # the head) is displaced as a whole by more than max_shift units relative to the
    # global fit -- the signature of a model that redrew or stretched the figure
    ok = stats["cover3"] >= 0.80 and stats["median"] <= 1.5 and (stats["worst_part_median"] or 0) <= 3.0 \
        and (stats["worst_part_shift"] or 0) <= max_shift
    stats["accept"] = bool(ok)
    return stats


def register(orig_rgb, gen_rgb, o_line=3.0, g_line=None, debug=False):
    """Returns dict with H (orig px -> gen px), residual stats (paper units), verdict."""
    units = 1000.0 / orig_rgb.shape[1]                  # paper units per original px
    if g_line is None:
        g_line = o_line * gen_rgb.shape[1] / orig_rgb.shape[1]
    o_mask, _, o_ok = ink_mask(orig_rgb, o_line, border=int(o_line * 2))
    g_mask, _, _ = ink_mask(gen_rgb, g_line)
    o_sk, P = skel_points(o_mask)
    g_sk, _ = skel_points(g_mask)
    dist, lab, coords = nearest_lookup(g_sk)
    gh, gw = g_sk.shape

    def lookup(Hc):
        q = apply_h(Hc, P)
        xi = np.clip(np.round(q[:, 0]).astype(int), 0, gw - 1)
        yi = np.clip(np.round(q[:, 1]).astype(int), 0, gh - 1)
        inside = (q[:, 0] >= 0) & (q[:, 0] < gw) & (q[:, 1] >= 0) & (q[:, 1] < gh)
        Q = coords[lab[yi, xi]]
        d = np.where(inside, np.hypot(*(Q - q).T), 1e9)
        return Q, d

    def scale_of(Hc):
        return np.sqrt(abs(np.linalg.det(Hc[:2, :2]))) / abs(Hc[2, 2])

    def cost(Hc):
        _, d = lookup(Hc)
        return float(np.minimum(d / scale_of(Hc) * units, 5.0).mean())   # truncated chamfer, paper units

    schedule = [("similarity", 12), ("similarity", 8), ("similarity", 6), ("affine", 6), ("affine", 4),
                ("homography", 4), ("homography", 3), ("homography", 2.5), ("homography", 2.5)]

    box = (P[:, 0].min(), P[:, 1].min(), P[:, 0].max(), P[:, 1].max())

    def refine(H):
        best_c = cost(H)
        for model, gate_units in schedule:
            Ht = H
            for _ in range(4):
                Q, d = lookup(Ht)
                gate = gate_units / units * scale_of(Ht)   # paper units -> generated px
                inl = d < gate
                if inl.sum() < 30:
                    break
                Hn = fit(model, P[inl], Q[inl])
                if Hn is None or not np.isfinite(Hn).all():
                    break
                Ht = Hn / Hn[2, 2]
            c = cost(Ht)
            if c <= best_c + 1e-9 and plausible(Ht, box):                     # a stage is kept only if it helps
                H, best_c = Ht, c
            if debug:
                print("  ", model, gate_units, round(c, 3), np.round(Ht, 3).tolist())
        return H, best_c

    best = None
    for ncc, H0 in coarse(o_mask, g_mask, o_line, g_line):
        if debug:
            print("coarse", round(ncc, 3), np.round(H0, 3).tolist())
        H, c = refine(H0)
        if best is None or c < best[0]:
            best = (c, H, ncc)
    _, H, ncc = best
    Q, d = lookup(H)
    s = scale_of(H)
    du = d / s * units                                  # residual in paper units
    # per-part systematic displacement: translation-only ICP of each connected part
    # of the original drawing, starting from the global fit
    n, labo = cv2.connectedComponents(o_mask.astype(np.uint8), connectivity=8)
    pi = labo[P[:, 1].astype(int), P[:, 0].astype(int)]
    pshift = np.zeros(len(P))
    gate = 6.0 / units * s
    for k in range(1, n):
        idx = np.nonzero(pi == k)[0]
        if len(idx) < 25:
            continue
        t = np.zeros(2)
        base = apply_h(H, P[idx])
        for _ in range(8):
            q = base + t
            xi = np.clip(np.round(q[:, 0]).astype(int), 0, gw - 1)
            yi = np.clip(np.round(q[:, 1]).astype(int), 0, gh - 1)
            Qk = coords[lab[yi, xi]]
            dk = np.hypot(*(Qk - q).T)
            m = dk < gate
            if m.sum() < 10:
                break
            t = t + (Qk[m] - q[m]).mean(0)
        pshift[idx] = np.hypot(*t) / s * units
    stats = verdict(du, P, o_mask, units, pshift=pshift)
    stats.update({"ncc": float(ncc), "scale_gen_px_per_orig_px": float(s)})
    return {"H": H, "stats": stats, "o_mask": o_mask, "g_mask": g_mask, "o_ok": o_ok, "du": du, "P": P, "pshift": pshift}
