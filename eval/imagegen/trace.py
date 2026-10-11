# Centre-line tracing of a binary ink mask into few, smooth, ordered cubic strokes.
#
#   skeleton -> pixel graph (endpoints, junction clusters, edges between them)
#   -> prune spurs -> pair edges straight-through at junctions -> chain into
#   polylines (closed loops detected) -> bridge small gaps between compatible
#   ends -> resample, split at real corners, Gaussian-smooth each piece
#   -> Schneider least-squares cubic fit per piece -> order (big shapes first)
#
# All lengths are in canvas px; the caller works in a canvas of 1 px = 1 paper unit.
import math
import numpy as np
import cv2
from skimage.morphology import skeletonize

N8 = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]


# ---------------------------------------------------------------- graph
def skeleton_graph(sk):
    h, w = sk.shape
    pts = set(zip(*np.nonzero(sk.T)))           # (x, y)

    def nbrs(p):
        x, y = p
        return [(x + dx, y + dy) for dx, dy in N8 if (x + dx, y + dy) in pts]

    deg = {p: len(nbrs(p)) for p in pts}
    # junction clusters: connected groups of pixels with degree >= 3
    node_of = {}
    nodes = []                                  # list of dict(pixels, center, kind)
    for p in pts:
        if deg[p] >= 3 and p not in node_of:
            stack, comp = [p], []
            node_of[p] = len(nodes)
            while stack:
                q = stack.pop(); comp.append(q)
                for r in nbrs(q):
                    if deg[r] >= 3 and r not in node_of:
                        node_of[r] = len(nodes); stack.append(r)
            c = np.mean(comp, 0)
            nodes.append({"pixels": comp, "center": (float(c[0]), float(c[1])), "kind": "junction"})
    for p in pts:
        if deg[p] <= 1:
            node_of[p] = len(nodes)
            nodes.append({"pixels": [p], "center": (float(p[0]), float(p[1])), "kind": "end" if deg[p] == 1 else "dot"})
    edges = []                                  # (a, b, [points])
    seen = set()
    for ni, nd in enumerate(nodes):
        for p in nd["pixels"]:
            for q in nbrs(p):
                if node_of.get(q) == ni:
                    continue
                if (p, q) in seen:
                    continue
                path = [p, q]
                prev, cur = p, q
                while cur not in node_of:
                    nx = [r for r in nbrs(cur) if r != prev and r not in path[-3:]]
                    if not nx:
                        break
                    # prefer 4-neighbours to avoid diagonal shortcuts
                    nx.sort(key=lambda r: abs(r[0] - cur[0]) + abs(r[1] - cur[1]))
                    prev, cur = cur, nx[0]
                    path.append(cur)
                seen.add((p, q)); seen.add((path[-1], path[-2]))
                b = node_of.get(cur, -1)
                edges.append([ni, b, path])
    # pure cycles (no nodes at all)
    covered = set(node_of)
    for e in edges:
        covered.update(e[2])
    rest = pts - covered
    while rest:
        p = rest.pop()
        path = [p]
        prev, cur = None, p
        while True:
            nx = [r for r in nbrs(cur) if r != prev and r in rest]
            if not nx:
                break
            prev, cur = cur, nx[0]
            rest.discard(cur); path.append(cur)
        if len(path) > 2:
            edges.append([-1, -1, path + [path[0]]])
    # dedupe edges found from both ends
    uniq, keyset = [], set()
    for a, b, path in edges:
        k = (min(path[0], path[-1]), max(path[0], path[-1]), len(path))
        if k in keyset:
            continue
        keyset.add(k)
        uniq.append([a, b, [tuple(map(float, q)) for q in path]])
    return nodes, uniq


def plen(path):
    a = np.asarray(path)
    return float(np.hypot(*np.diff(a, axis=0).T).sum()) if len(a) > 1 else 0.0


def prune_spurs(nodes, edges, spur):
    """Remove short end-branches hanging off junctions (repeat until stable)."""
    changed = True
    while changed:
        changed = False
        count = {}
        for a, b, _ in edges:
            count[a] = count.get(a, 0) + 1
            count[b] = count.get(b, 0) + 1
        keep = []
        for e in edges:
            a, b, path = e
            ka = nodes[a]["kind"] if a >= 0 else "loop"
            kb = nodes[b]["kind"] if b >= 0 else "loop"
            spurry = (ka == "end" and kb == "junction" and count.get(b, 0) >= 3) or \
                     (kb == "end" and ka == "junction" and count.get(a, 0) >= 3)
            if spurry and plen(path) < spur:
                changed = True
                continue
            keep.append(e)
        edges = keep
    return edges


def direction_from(path, at_start, look):
    """Unit vector pointing from the path end into the path, averaged over `look` px."""
    a = np.asarray(path if at_start else path[::-1])
    acc = 0.0
    for i in range(1, len(a)):
        acc += math.hypot(*(a[i] - a[i - 1]))
        if acc >= look:
            break
    v = a[i] - a[0]
    n = math.hypot(*v)
    return v / n if n > 0 else np.zeros(2)


def chain(nodes, edges, look=8.0, max_turn=50.0):
    """Pair edges through each junction for the straightest continuation; walk chains."""
    inc = {}                                    # node -> [(edge index, at_start)]
    for i, (a, b, _) in enumerate(edges):
        if a >= 0:
            inc.setdefault(a, []).append((i, True))
        if b >= 0:
            inc.setdefault(b, []).append((i, False))
    link = {}                                   # (edge, end) -> (edge, end)
    cos_lim = -math.cos(math.radians(max_turn))
    for n, lst in inc.items():
        if nodes[n]["kind"] != "junction":
            continue
        if len(lst) == 2 and lst[0][0] != lst[1][0]:
            # only two branches left after spur pruning: a pass-through point (often a
            # sharp tip such as a cat's ear) -- always continue, the corner survives
            # in the curve fit
            link[lst[0]] = lst[1]; link[lst[1]] = lst[0]
            continue
        cand = []
        for x in range(len(lst)):
            for y in range(x + 1, len(lst)):
                (ei, si), (ej, sj) = lst[x], lst[y]
                if ei == ej:
                    continue
                di = direction_from(edges[ei][2], si, look)
                dj = direction_from(edges[ej][2], sj, look)
                c = float(np.dot(di, dj))          # -1: perfectly straight through
                if c <= cos_lim:
                    cand.append((c, lst[x], lst[y]))
        cand.sort(key=lambda t: t[0])
        used = set()
        for c, u, v in cand:
            if u in used or v in used:
                continue
            used.update([u, v]); link[u] = v; link[v] = u
    # walk
    done = set()
    lines = []
    for i in range(len(edges)):
        if i in done:
            continue
        seq = [(i, False)]                      # (edge, reversed?)
        done.add(i)
        e, leave_start = i, False               # walk forward, leaving edge i at its end
        closed = False
        while (e, leave_start) in link:
            ne, ns = link[(e, leave_start)]     # ns: ne's START is at this junction
            if ne == i:
                closed = True
                break
            if ne in done:
                break
            done.add(ne)
            seq.append((ne, not ns))
            e, leave_start = ne, not ns
        if not closed:
            e, leave_start = i, True            # walk backward from edge i's start
            while (e, leave_start) in link:
                ne, ns = link[(e, leave_start)]
                if ne in done:
                    break
                done.add(ne)
                seq.insert(0, (ne, ns))
                e, leave_start = ne, not ns
        pts = []
        for ei, rev in seq:
            p = edges[ei][2][::-1] if rev else edges[ei][2]
            pts.extend(p if not pts else p[1:])
        if not closed:
            # an end that stops at a junction (T-joint) should reach the junction centre
            e0, r0 = seq[0]
            n0 = edges[e0][1] if r0 else edges[e0][0]
            e1, r1 = seq[-1]
            n1 = edges[e1][0] if r1 else edges[e1][1]
            if n0 >= 0 and nodes[n0]["kind"] == "junction":
                pts = [nodes[n0]["center"]] + pts
            if n1 >= 0 and nodes[n1]["kind"] == "junction":
                pts = pts + [nodes[n1]["center"]]
        if not closed and len(pts) > 3 and math.hypot(pts[0][0] - pts[-1][0], pts[0][1] - pts[-1][1]) < 1.5:
            closed = True
        if edges[i][0] == -1 and edges[i][1] == -1:
            closed = True
        lines.append({"pts": pts, "closed": closed})
    return lines


# ---------------------------------------------------------------- gap bridging
def bridge(lines, gap, max_turn=40.0, look=8.0, touch=2.5):
    """Join open ends that are close and point at each other."""
    cos_lim = math.cos(math.radians(max_turn))
    while True:
        ends = []
        for i, l in enumerate(lines):
            if l["closed"] or len(l["pts"]) < 2:
                continue
            for at_start in (True, False):
                p = np.array(l["pts"][0 if at_start else -1])
                d = -direction_from(l["pts"], at_start, look)   # pointing outwards
                ends.append((i, at_start, p, d))
        best = None
        for x in range(len(ends)):
            for y in range(x + 1, len(ends)):
                i, si, p, dp = ends[x]
                j, sj, q, dq = ends[y]
                v = q - p
                dist = math.hypot(*v)
                if dist > gap or dist < 1e-6:
                    continue
                u = v / dist
                if dist <= touch:
                    if np.dot(dp, dq) > 0.95:            # ends retrace each other
                        continue
                elif np.dot(dp, u) < cos_lim or np.dot(dq, -u) < cos_lim:
                    continue
                score = dist * (2.0 - np.dot(dp, u) - np.dot(dq, -u) + 0.2)
                if i == j:
                    # closing a loop on itself: only if the line is long relative to the gap
                    if plen(lines[i]["pts"]) < 6 * dist:
                        continue
                if best is None or score < best[0]:
                    best = (score, i, si, j, sj)
        if best is None:
            return lines
        _, i, si, j, sj = best
        if i == j:
            lines[i]["closed"] = True
            continue
        a = lines[i]["pts"][::-1] if si else lines[i]["pts"]      # a ends at the joined end
        b = lines[j]["pts"] if sj else lines[j]["pts"][::-1]      # b starts at the joined end
        lines[i] = {"pts": a + b, "closed": False}
        del lines[j]


def uncovered(mask, p, q):
    """Length (px) of the segment p-q that runs over blank paper."""
    n = int(math.hypot(q[0] - p[0], q[1] - p[1])) + 2
    xs = np.clip(np.round(np.linspace(p[0], q[0], n)).astype(int), 0, mask.shape[1] - 1)
    ys = np.clip(np.round(np.linspace(p[1], q[1], n)).astype(int), 0, mask.shape[0] - 1)
    return (~mask[ys, xs]).mean() * math.hypot(q[0] - p[0], q[1] - p[1])


def reach(lines, gap, look=8.0, touch=2.5, max_turn=60.0, mask=None):
    """An open end that stops just short of ANOTHER line (a T-joint broken by a grid
    line, or the skeleton's retraction at a corner) is extended to touch it -- but only
    across ink: at most `touch` of the connecting segment may be blank paper."""
    from scipy.spatial import cKDTree
    if len(lines) < 2:
        return lines
    pts, owner, idx = [], [], []
    for i, l in enumerate(lines):
        for j, p in enumerate(l["pts"]):
            pts.append(p); owner.append(i); idx.append(j)
    pts = np.asarray(pts); owner = np.asarray(owner); idx = np.asarray(idx)
    tree = cKDTree(pts)
    cos_lim = math.cos(math.radians(max_turn))
    for i, l in enumerate(lines):
        if l["closed"] or len(l["pts"]) < 3:
            continue
        n = len(l["pts"])
        for at_start in (True, False):
            p = np.asarray(l["pts"][0 if at_start else -1])
            d = -direction_from(l["pts"], at_start, look)
            best = None
            for k in tree.query_ball_point(p, gap):
                if owner[k] == i:
                    # own line: only far along the line (a loop closing onto itself)
                    j = idx[k]
                    if (j if at_start else n - 1 - j) < 4 * gap:
                        continue
                v = pts[k] - p
                dist = math.hypot(*v)
                if dist < 1e-6:
                    continue
                if np.dot(d, v / dist) < cos_lim and dist > touch:
                    continue
                if mask is not None and uncovered(mask, p, pts[k]) > touch:
                    continue
                if best is None or dist < best[0]:
                    best = (dist, k)
            if best is None or best[0] < 0.75:
                continue
            q = tuple(pts[best[1]])
            if at_start:
                l["pts"] = [q] + l["pts"]
            else:
                l["pts"] = l["pts"] + [q]
    return lines


# ---------------------------------------------------------------- smoothing + fitting
def resample(pts, step=1.0, closed=False):
    a = np.asarray(pts, float)
    if closed:
        a = np.vstack([a, a[:1]])
    seg = np.hypot(*np.diff(a, axis=0).T)
    keep = np.r_[True, seg > 1e-9]
    a = a[keep]
    s = np.r_[0, np.cumsum(np.hypot(*np.diff(a, axis=0).T))]
    if s[-1] < step:
        return a
    n = max(int(round(s[-1] / step)), 2)
    t = np.linspace(0, s[-1], n + 1)
    out = np.c_[np.interp(t, s, a[:, 0]), np.interp(t, s, a[:, 1])]
    return out[:-1] if closed else out


def smooth(a, sigma, closed):
    if len(a) < 5 or sigma <= 0:
        return a
    r = int(3 * sigma)
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma) ** 2); k /= k.sum()
    if closed:
        ext = np.vstack([a[-r:], a, a[:r]])
        return np.c_[np.convolve(ext[:, 0], k, "valid"), np.convolve(ext[:, 1], k, "valid")]
    # open: pad by reflection through the end points so ends stay put
    pre = 2 * a[0] - a[1:r + 1][::-1]
    post = 2 * a[-1] - a[-r - 1:-1][::-1]
    ext = np.vstack([pre, a, post])
    out = np.c_[np.convolve(ext[:, 0], k, "valid"), np.convolve(ext[:, 1], k, "valid")]
    out[0], out[-1] = a[0], a[-1]
    return out


def corners(a, closed, win=5, min_angle=50.0, min_gap=6):
    """Indices where the direction turns sharply over +-win samples (cat ears, roof)."""
    n = len(a)
    if n < 2 * win + 3:
        return []
    ang = np.zeros(n)
    for i in range(n):
        if not closed and (i < win or i >= n - win):
            continue
        p, q, r = a[(i - win) % n], a[i], a[(i + win) % n]
        u, v = q - p, r - q
        nu, nv = np.hypot(*u), np.hypot(*v)
        if nu < 1e-6 or nv < 1e-6:
            continue
        ang[i] = math.degrees(math.acos(np.clip(np.dot(u, v) / (nu * nv), -1, 1)))
    out = []
    order = np.argsort(-ang)
    for i in order:
        if ang[i] < min_angle:
            break
        if all(min(abs(i - j), n - abs(i - j) if closed else 1e9) >= min_gap for j in out):
            out.append(int(i))
    return sorted(out)


def bezier_pt(b, t):
    t = np.asarray(t)[:, None]
    mt = 1 - t
    return mt ** 3 * b[0] + 3 * mt ** 2 * t * b[1] + 3 * mt * t ** 2 * b[2] + t ** 3 * b[3]


def fit_cubic(pts, tol, depth=0):
    """Schneider-style recursive least-squares cubic fitting with chord-length params."""
    pts = np.asarray(pts, float)
    n = len(pts)
    if n < 2:
        return []
    chord = pts[-1] - pts[0]
    cl = np.hypot(*chord)
    rel = pts - pts[0]
    if n == 2 or (cl > 0 and (np.abs(chord[0] * rel[:, 1] - chord[1] * rel[:, 0]) / cl).max() <= min(tol, 0.6)):
        # straight within tolerance: a true straight line, not a wobbly curve
        d = chord / 3
        return [np.array([pts[0], pts[0] + d, pts[-1] - d, pts[-1]])]
    # end tangents from ~4 units in, so a pixel-scale hook at the end does not bend it
    k = min(4, n - 1)
    t_hat1 = pts[k] - pts[0]
    t_hat2 = pts[n - 1 - k] - pts[-1]
    t_hat1 /= np.hypot(*t_hat1) or 1
    t_hat2 /= np.hypot(*t_hat2) or 1
    u = np.r_[0, np.cumsum(np.hypot(*np.diff(pts, axis=0).T))]
    u /= u[-1] if u[-1] > 0 else 1

    def solve(u):
        A1 = (3 * (1 - u) ** 2 * u)[:, None] * t_hat1
        A2 = (3 * (1 - u) * u ** 2)[:, None] * t_hat2
        C = np.array([[np.sum(A1 * A1), np.sum(A1 * A2)], [np.sum(A1 * A2), np.sum(A2 * A2)]])
        base = bezier_pt(np.array([pts[0], pts[0], pts[-1], pts[-1]]), u)
        X = np.array([np.sum(A1 * (pts - base)), np.sum(A2 * (pts - base))])
        det = np.linalg.det(C)
        seg = np.hypot(*(pts[-1] - pts[0]))
        if abs(det) > 1e-12:
            a1, a2 = np.linalg.solve(C, X)
        else:
            a1 = a2 = seg / 3
        if a1 < 1e-3 * seg or a2 < 1e-3 * seg or a1 > 2 * seg + 5 or a2 > 2 * seg + 5:
            a1 = a2 = seg / 3
        return np.array([pts[0], pts[0] + a1 * t_hat1, pts[-1] + a2 * t_hat2, pts[-1]])

    b = solve(u)
    for _ in range(4):                          # Newton reparameterisation
        q = bezier_pt(b, u)
        d1 = 3 * ((1 - u)[:, None] ** 2 * (b[1] - b[0]) + 2 * ((1 - u) * u)[:, None] * (b[2] - b[1]) + (u[:, None] ** 2) * (b[3] - b[2]))
        d2 = 6 * ((1 - u)[:, None] * (b[2] - 2 * b[1] + b[0]) + u[:, None] * (b[3] - 2 * b[2] + b[1]))
        num = np.sum((q - pts) * d1, 1)
        den = np.sum(d1 * d1, 1) + np.sum((q - pts) * d2, 1)
        u = np.clip(u - np.divide(num, den, out=np.zeros_like(num), where=np.abs(den) > 1e-12), 0, 1)
        u[0], u[-1] = 0, 1
        u = np.maximum.accumulate(u)
        b = solve(u)
    err = np.hypot(*(bezier_pt(b, u) - pts).T)
    if err.max() <= tol or n <= 4 or depth > 12:
        return [b]
    k = int(np.clip(np.argmax(err), 2, n - 3))
    return fit_cubic(pts[:k + 1], tol, depth + 1) + fit_cubic(pts[k:], tol, depth + 1)


def fit_line(a, closed, tol):
    """Polyline (smoothed) -> list of cubic segments, split at corners."""
    cs = corners(a, closed)
    if closed:
        if cs:
            a = np.roll(a, -cs[0], axis=0)
            cs = [c - cs[0] for c in cs] + [len(a)]
            a = np.vstack([a, a[:1]])
        else:
            a = np.vstack([a, a[:1]])
            cs = [0, len(a) - 1]
    else:
        cs = [0] + cs + [len(a) - 1]
    segs = []
    for i in range(len(cs) - 1):
        piece = a[cs[i]:cs[i + 1] + 1]
        segs += fit_cubic(piece, tol)
    return segs


def to_d(segs, closed, nd=1):
    f = lambda v: f"{v:.{nd}f}".rstrip("0").rstrip(".")
    d = [f"M {f(segs[0][0][0])} {f(segs[0][0][1])}"]
    for b in segs:
        d.append("C " + " ".join(f"{f(p[0])} {f(p[1])}" for p in b[1:]))
    if closed:
        d.append("Z")
    return " ".join(d)


def sample_segs(segs, per=12):
    out = [segs[0][0]]
    for b in segs:
        out.extend(bezier_pt(b, np.linspace(0, 1, per + 1)[1:]))
    return np.array(out)


# ---------------------------------------------------------------- top level
def trace(mask, ppu=1.0, spur=5.0, gap=6.0, min_len=8.0, sigma=1.6, tol=0.8, snap_to=None, snap_dist=0.0):
    """mask: bool canvas with ppu px per paper unit; all other lengths in paper units.
    snap_to: optional (dist, coords, labels) nearest-pixel lookup of the ORIGINAL
    drawing in canvas px; open ends that stop within snap_dist of it (because the
    original's neighbourhood was masked out) are extended to touch it.
    Returns strokes with coordinates in paper units."""
    m = mask.astype(np.uint8)
    # fill pin-holes so thick lines do not skeletonize into ladders
    m = cv2.morphologyEx(m, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3)))
    inv = 1 - m
    n, lab, stats, _ = cv2.connectedComponentsWithStats(inv, connectivity=4)
    for k in range(1, n):
        if stats[k, cv2.CC_STAT_AREA] < 12 * ppu * ppu:
            m[lab == k] = 1
    sk = skeletonize(m > 0)
    nodes, edges = skeleton_graph(sk)
    edges = prune_spurs(nodes, edges, spur * ppu)
    lines = chain(nodes, edges, look=8.0 * ppu)
    lines = [l for l in lines if len(l["pts"]) >= 2]
    lines = bridge(lines, gap * ppu, look=8.0 * ppu, touch=2.5 * ppu)
    md = cv2.dilate(m, np.ones((3, 3), np.uint8)) > 0
    lines = reach(lines, 10.0 * ppu, look=8.0 * ppu, touch=2.5 * ppu, mask=md)
    if snap_to is not None:
        dist, coords, lab2 = snap_to
        h, w = dist.shape
        for l in lines:
            if l["closed"]:
                continue
            for at_start in (True, False):
                p = np.array(l["pts"][0 if at_start else -1])
                xi, yi = int(round(p[0])), int(round(p[1]))
                if not (0 <= xi < w and 0 <= yi < h) or dist[yi, xi] > snap_dist * ppu:
                    continue
                q = coords[lab2[yi, xi]]
                out = -direction_from(l["pts"], at_start, 8.0 * ppu)
                v = q - p
                nv = np.hypot(*v)
                if nv < 0.5 or np.dot(out, v / nv) < math.cos(math.radians(60)):
                    continue
                if at_start:
                    l["pts"] = [tuple(q)] + l["pts"]
                else:
                    l["pts"] = l["pts"] + [tuple(q)]
    strokes = []
    for l in lines:
        pts = np.asarray(l["pts"], float) / ppu          # paper units from here on
        L = plen(pts)
        if L < min_len:
            continue
        a = resample(pts, 1.0, l["closed"])
        a = smooth(a, sigma, l["closed"])
        if len(a) < 3:
            continue
        segs = fit_line(a, l["closed"], tol)
        strokes.append({"segs": segs, "closed": l["closed"], "len": L, "poly": a})
    return order(strokes)


def order(strokes):
    """Big shapes first (contours, by length), then details nearest-next."""
    if not strokes:
        return []
    for s in strokes:
        a = s["poly"]
        s["bbox"] = (a[:, 0].min(), a[:, 1].min(), a[:, 0].max(), a[:, 1].max())
    allb = np.array([s["bbox"] for s in strokes])
    diag = math.hypot(allb[:, 2].max() - allb[:, 0].min(), allb[:, 3].max() - allb[:, 1].min())
    Ltot = sum(s["len"] for s in strokes)
    for s in strokes:
        bd = math.hypot(s["bbox"][2] - s["bbox"][0], s["bbox"][3] - s["bbox"][1])
        s["role"] = "contour" if (s["len"] >= max(20.0, 0.035 * Ltot) or bd >= 0.3 * diag) else "detail"
    cont = sorted([s for s in strokes if s["role"] == "contour"], key=lambda s: -s["len"])
    det = [s for s in strokes if s["role"] == "detail"]
    out = list(cont)
    cur = out[-1]["poly"][-1] if out else np.array([0.0, 0.0])
    while det:
        i = min(range(len(det)), key=lambda k: min(np.hypot(*(det[k]["poly"][0] - cur)), np.hypot(*(det[k]["poly"][-1] - cur))))
        s = det.pop(i)
        out.append(s)
        cur = s["poly"][-1]
    # open strokes start at their upper-left end, as most people would
    for s in out:
        if not s["closed"]:
            a, b = s["poly"][0], s["poly"][-1]
            if (b[0] + b[1]) < (a[0] + a[1]) - 2:
                s["segs"] = [seg[::-1] for seg in s["segs"][::-1]]
                s["poly"] = s["poly"][::-1]
    return out
