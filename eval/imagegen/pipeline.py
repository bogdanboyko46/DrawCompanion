# Generated image -> registered -> new ink only -> traced strokes in paper units.
#
#   python pipeline.py <original.jpg> <generated.jpg> <out_prefix> [label]
#
# Writes <out_prefix>.json  {"accept", "registration": {...}, "strokes": [...], "ms": {...}}
#        <out_prefix>.png   4 panels: generated | registered check | new ink | final on photo
import json, math, os, sys, time
import numpy as np
import cv2
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ink import ink_mask, paper_bg, red_mask, page_mask
from register import register, verdict
from trace import trace, to_d, sample_segs

PPU = 2            # canvas px per paper unit (the generated image has ~1.1 px per unit)
R_OLD = 5.0        # paper units: generated ink this close to an original line is the original line


def grid_masks(orig, line_px=3.0):
    """Blue grid lines and blue labels baked into the page photo (original px)."""
    img = orig.astype(np.float32)
    n = np.clip(img / paper_bg(img, line_px), 0, 1.2)
    blue = ((n[..., 2] - n[..., 0]) > 0.1) & ((1 - n[..., 0]) > 0.12)
    blue = blue.astype(np.uint8)
    L = 31
    lines = cv2.morphologyEx(blue, cv2.MORPH_OPEN, np.ones((1, L), np.uint8)) | \
        cv2.morphologyEx(blue, cv2.MORPH_OPEN, np.ones((L, 1), np.uint8))
    labels = blue & (1 - cv2.dilate(lines, np.ones((5, 5), np.uint8)))
    return lines > 0, labels > 0


def nearest(sk):
    inv = (~sk).astype(np.uint8)
    dist, lab = cv2.distanceTransformWithLabels(inv, cv2.DIST_L2, 5, labelType=cv2.DIST_LABEL_PIXEL)
    ys, xs = np.nonzero(inv == 0)
    coords = np.zeros((lab.max() + 1, 2), np.float64)
    coords[lab[ys, xs]] = np.stack([xs, ys], 1)
    return dist, coords, lab


def process(orig_path, gen_path, verbose=False):
    t0 = time.time()
    orig = np.asarray(Image.open(orig_path).convert("RGB"))
    gen = np.asarray(Image.open(gen_path).convert("RGB"))
    units = 1000.0 / orig.shape[1]
    Wu, Hu = 1000, int(round(orig.shape[0] * units))     # page size in paper units
    W, H = Wu * PPU, Hu * PPU                            # working canvas
    reg = register(orig, gen)
    t_reg = time.time()
    st = reg["stats"]
    out = {"registration": {k: v for k, v in st.items() if k != "parts"}, "parts": st["parts"], "accept": st["accept"]}
    # canvas px -> original px -> generated px
    S = np.diag([1 / (units * PPU), 1 / (units * PPU), 1.0])
    M = reg["H"] @ S
    gmask = cv2.warpPerspective(reg["g_mask"].astype(np.float32), M, (W, H),
                                flags=cv2.INTER_LINEAR | cv2.WARP_INVERSE_MAP) > 0.5
    gwarp = cv2.warpPerspective(gen, M, (W, H), flags=cv2.INTER_LINEAR | cv2.WARP_INVERSE_MAP,
                                borderValue=(128, 128, 128))
    # where the original page is (with a margin for the sheet edge)
    _, _, o_ok = ink_mask(orig, 3.0, border=int(3.0 * 2))
    ok_c = cv2.resize(o_ok.astype(np.uint8), (W, H), interpolation=cv2.INTER_NEAREST) > 0
    # ...and where the generated image actually shows paper: a model may crop or zoom,
    # so part of the page can lie outside its frame; its frame edge and any dark
    # surround (page edge, table) are not drawing
    g_ok, _ = page_mask(gen, max(3.0, gen.shape[1] / 300))
    e = max(8, gen.shape[1] // 100)
    g_ok[:e] = g_ok[-e:] = False
    g_ok[:, :e] = g_ok[:, -e:] = False
    g_ok_c = cv2.warpPerspective(g_ok.astype(np.uint8), M, (W, H),
                                 flags=cv2.INTER_NEAREST | cv2.WARP_INVERSE_MAP) > 0
    ok_c &= g_ok_c
    gmask &= ok_c
    # original drawing, as a thin skeleton in the canvas
    osk = np.zeros((H, W), bool)
    P = reg["P"] * units * PPU
    osk[np.clip(np.round(P[:, 1]).astype(int), 0, H - 1), np.clip(np.round(P[:, 0]).astype(int), 0, W - 1)] = True
    osk = cv2.dilate(osk.astype(np.uint8), np.ones((PPU, PPU), np.uint8)) > 0
    dist_o, coords_o, lab_o = nearest(osk)
    dist_u = dist_o / PPU                                # paper units to the nearest original line
    # baked-in grid: remove long axis-aligned runs of generated ink that sit on a grid line
    # (models that turn the blue grid grey), and components sitting mostly on a grid label
    glines, glabels = grid_masks(orig)
    k3 = int(3 * PPU) * 2 + 1
    gl_c = cv2.dilate(cv2.resize(glines.astype(np.uint8), (W, H), interpolation=cv2.INTER_NEAREST),
                      np.ones((k3, k3), np.uint8)) > 0
    lb_c = cv2.dilate(cv2.resize(glabels.astype(np.uint8), (W, H), interpolation=cv2.INTER_NEAREST),
                      np.ones((k3, k3), np.uint8)) > 0
    g8 = gmask.astype(np.uint8)
    L = 60 * PPU + 1
    runs = cv2.morphologyEx(g8, cv2.MORPH_OPEN, np.ones((1, L), np.uint8)) | cv2.morphologyEx(g8, cv2.MORPH_OPEN, np.ones((L, 1), np.uint8))
    grid_ink = cv2.dilate(((runs > 0) & gl_c).astype(np.uint8), np.ones((2 * PPU + 1,) * 2, np.uint8)) > 0
    new = gmask & ~grid_ink & (dist_u > R_OLD)
    # colour-coded variant: if the model drew the new object in red, the new ink is
    # simply the red ink (no difference against the original needed)
    rmask, _ = red_mask(gen, max(3.0, gen.shape[1] / 400))
    mode = "red" if rmask.sum() > 200 else "diff"
    if mode == "red":
        new = cv2.warpPerspective(rmask.astype(np.float32), M, (W, H),
                                  flags=cv2.INTER_LINEAR | cv2.WARP_INVERSE_MAP) > 0.5
        new &= ok_c
    out["mode"] = mode
    if mode == "red":
        # original lines within 8 units of the new red ink were part of the edit
        # (the model may redraw the smile it was asked to add teeth to): they do not
        # count against the registration verdict
        dr = cv2.distanceTransform((~new).astype(np.uint8), cv2.DIST_L2, 5) / PPU
        Pi = np.clip(np.round(reg["P"] * units * PPU).astype(int), 0, [W - 1, H - 1])
        excl = dr[Pi[:, 1], Pi[:, 0]] < 8.0
        st2 = verdict(reg["du"], reg["P"], reg["o_mask"], units, exclude=excl, pshift=reg["pshift"])
        st2.update({"ncc": st["ncc"], "scale_gen_px_per_orig_px": st["scale_gen_px_per_orig_px"]})
        out["registration"] = {k: v for k, v in st2.items() if k != "parts"}
        out["parts"], out["accept"] = st2["parts"], st2["accept"]
    # component clean-up: slivers that hug an original line, label remnants, dust
    n, lab, stats, _ = cv2.connectedComponentsWithStats(new.astype(np.uint8), connectivity=8)
    keep = np.zeros(n, bool)
    for k in range(1, n):
        area = stats[k, cv2.CC_STAT_AREA] / PPU ** 2
        span = max(stats[k, cv2.CC_STAT_WIDTH], stats[k, cv2.CC_STAT_HEIGHT]) / PPU
        if span < 6 or area < 12:
            continue
        x, y, w, h = stats[k, :4]
        sel = lab[y:y + h, x:x + w] == k
        if mode == "diff" and dist_u[y:y + h, x:x + w][sel].max() < R_OLD + 3:   # hugs an original line
            continue
        if lb_c[y:y + h, x:x + w][sel].mean() > 0.6:          # a grid label the model redrew
            continue
        keep[k] = True
    new = keep[lab]
    strokes = trace(new, ppu=PPU, snap_to=(dist_o, coords_o, lab_o) if mode == "diff" else None, snap_dist=R_OLD + 3)
    t_end = time.time()
    out["strokes"] = [{"role": s["role"], "weight": "medium", "d": to_d(s["segs"], s["closed"])} for s in strokes]
    out["stats"] = {"strokes": len(strokes), "segments": sum(len(s["segs"]) for s in strokes),
                    "new_ink_units2": int(new.sum() / PPU ** 2)}
    out["ms"] = {"register": int((t_reg - t0) * 1000), "extract_trace": int((t_end - t_reg) * 1000),
                 "total": int((t_end - t0) * 1000)}
    out["paper"] = {"w": Wu, "h": Hu}
    dbg = {"orig": orig, "gen": gen, "gwarp": gwarp, "new": new, "osk": osk, "gmask": gmask, "strokes": strokes,
           "units": units}
    return out, dbg


def font(sz=14):
    for f in ("/System/Library/Fonts/Supplemental/Arial.ttf", "DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(f, sz)
        except OSError:
            pass
    return ImageFont.load_default()


def draw_strokes(photo, strokes_segs, units, scale=2.0, color=(225, 0, 0), numbers=True):
    im = Image.fromarray(photo).resize((int(photo.shape[1] * scale), int(photo.shape[0] * scale)), Image.LANCZOS)
    d = ImageDraw.Draw(im)
    k = scale / units
    f = font(13)
    for i, s in enumerate(strokes_segs):
        pts = sample_segs(s["segs"]) * k
        col = color if s["role"] == "contour" else (255, 120, 0)
        d.line([tuple(p) for p in pts], fill=col, width=3, joint="curve")
        if numbers:
            x, y = pts[0]
            d.ellipse([x - 3, y - 3, x + 3, y + 3], fill=(0, 90, 255))
            d.text((x + 4, y - 14), str(i + 1), fill=(0, 60, 200), font=f)
    return im


def panels(out, dbg, title):
    units = dbg["units"]
    orig = dbg["orig"]
    h0, w0 = orig.shape[:2]
    sc = 2
    tw, th = w0 * sc, h0 * sc
    # 1 generated (as returned), fitted into the tile
    g = Image.fromarray(dbg["gen"]); g.thumbnail((tw, th))
    p1 = Image.new("RGB", (tw, th), (255, 255, 255)); p1.paste(g, ((tw - g.width) // 2, (th - g.height) // 2))
    # 2 registered generated image (canvas) with the original skeleton in red
    gw = cv2.resize(dbg["gwarp"], (tw, th), interpolation=cv2.INTER_AREA)
    gw = (0.6 * gw + 0.4 * 255).astype(np.uint8)
    osk = cv2.dilate(cv2.resize(dbg["osk"].astype(np.uint8), (tw, th), interpolation=cv2.INTER_NEAREST), np.ones((2, 2), np.uint8)) > 0
    gw[osk] = (230, 0, 0)
    p2 = Image.fromarray(gw)
    # 3 extracted new ink (black) over faint original lines
    nm = np.full((dbg["new"].shape[0], dbg["new"].shape[1], 3), 255, np.uint8)
    nm[cv2.dilate(dbg["osk"].astype(np.uint8), np.ones((3, 3), np.uint8)) > 0] = (200, 200, 200)
    nm[dbg["gmask"] & ~dbg["new"]] = (170, 200, 255)
    nm[dbg["new"]] = (0, 0, 0)
    p3 = Image.fromarray(cv2.resize(nm, (tw, th), interpolation=cv2.INTER_NEAREST))
    # 4 final strokes on the ORIGINAL photo
    p4 = draw_strokes(orig, dbg["strokes"], units, sc)
    # 5/6 zoom on the new drawing: strokes on the photo, and strokes over the extracted ink
    ys, xs = np.nonzero(dbg["new"])
    xs, ys = xs / PPU, ys / PPU
    if len(xs):
        x0, x1, y0, y1 = xs.min() - 15, xs.max() + 15, ys.min() - 15, ys.max() + 15
    else:
        x0, x1, y0, y1 = 0, 1000, 0, int(orig.shape[0] * units)
    zw = max(x1 - x0, (y1 - y0) * tw / th)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    zh = zw * th / tw
    box = (cx - zw / 2, cy - zh / 2, cx + zw / 2, cy + zh / 2)
    z = 4
    big = draw_strokes(orig, dbg["strokes"], units, z, numbers=True)
    k = z / units
    p5 = big.crop(tuple(int(v * k) for v in box)).resize((tw, th), Image.LANCZOS)
    nm2 = np.full(nm.shape, 255, np.uint8)
    nm2[dbg["new"]] = (150, 150, 150)
    nm2[cv2.dilate(dbg["osk"].astype(np.uint8), np.ones((2, 2), np.uint8)) > 0] = (190, 210, 255)
    big2 = draw_strokes(nm2, dbg["strokes"], 1.0 / PPU, z / PPU, numbers=False)
    p6 = big2.crop(tuple(int(v * z) for v in box)).resize((tw, th), Image.LANCZOS)
    sheet = Image.new("RGB", (tw * 3 + 20, th * 2 + 40), (255, 255, 255))
    for i, p in enumerate([p1, p2, p3, p4, p5, p6]):
        sheet.paste(p, ((i % 3) * (tw + 10), (i // 3) * (th + 5)))
    d = ImageDraw.Draw(sheet)
    r = out["registration"]
    cap = (f"{title}   {'ACCEPT' if out['accept'] else 'REJECT'}  residual median {r['median']:.2f} u, p90 {r['p90']:.2f} u, "
           f"cover3 {r['cover3']:.0%}, worst part {r['worst_part_median'] or 0:.1f} u   "
           f"{out['stats']['strokes']} strokes / {out['stats']['segments']} cubics   {out['ms']['total']} ms")
    d.text((8, th * 2 + 14), cap, fill=(0, 0, 0), font=font(18))
    return sheet


if __name__ == "__main__":
    orig_path, gen_path, prefix = sys.argv[1:4]
    title = sys.argv[4] if len(sys.argv) > 4 else os.path.basename(prefix)
    out, dbg = process(orig_path, gen_path)
    json.dump(out, open(prefix + ".json", "w"), indent=1)
    panels(out, dbg, title).save(prefix + ".png")
    print(json.dumps({"accept": out["accept"], **{k: round(v, 3) if isinstance(v, float) else v for k, v in out["registration"].items()},
                      **out["stats"], **out["ms"]}))
