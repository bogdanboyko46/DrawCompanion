# Upgrade server: page photo + request -> image model -> registered, traced strokes.
#
#   .../venv/bin/python eval/imagegen/server.py [--port 8787] [--model gpt-image-2-5-flare]
#
# GET  /health   -> {"ok": true}
# POST /upgrade  {"page_jpeg": b64, "paper": {"w":1000,"h":H}, "said": [...],
#                 "box": {"x0","y0","x1","y1"} (paper units), "id": "..."}
#             -> {"ok": true, "strokes": [{"role","weight","d"}], "ms": {...}, ...}
#              | {"ok": false, "reason": "...", "ms": {...}}
# Strokes are in paper units: page 1000 wide, origin top-left, same frame as the photo.
# Never returns strokes that failed the registration gate, the overlap check or the
# placement check; the app then keeps Claude's outline.
import base64, hashlib, hmac, io, json, os, re, sys, threading, time, traceback, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
from PIL import Image

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
import pipeline
from prep import clean
from ink import ink_mask

ENV = "/Users/brandonj/DrawCompanion/.env"
MESHY = "https://api.meshy.ai/openapi/v1/image-to-image"
DEADLINE_S = 40.0          # hard overall budget per request
PROCESS_RESERVE_S = 4.0    # leave this much for registration + tracing
LOG = os.path.join(here, "calls.jsonl")
SAVE_DIR = None            # --save-dir: keep every generated bitmap for debugging
_log_lock = threading.Lock()


def load_key(name="MESHY_API_KEY"):
    for line in open(ENV):
        line = line.strip()
        if line.startswith(name + "="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise SystemExit(name + " not found in " + ENV)


KEY = load_key()
# Shared secret: the app sends SHA-256("drawcompanion-upgrade:" + its Claude API
# key) in X-DC-Token. Only someone holding that key can spend Meshy credits here.
TOKEN = hashlib.sha256(("drawcompanion-upgrade:" + load_key("ANTHROPIC_API_KEY")).encode()).hexdigest()

# Requests about a part of the existing figure: the new lines legitimately sit on it.
ON_PART = re.compile(r"\b(hat|cap|crown|helmet|teeth|tooth|button|buttons|nose|eye|eyes|eyebrow|eyebrows|"
                     r"mouth|smile|lips|tongue|hair|beard|mustache|moustache|glasses|sunglasses|mask|"
                     r"earring|earrings|scarf|tie|bow|collar|shirt|dress|clothes|belt|pocket|shoes|shoe|boots|"
                     r"socks|gloves|glove|freckles|cheeks|whiskers|horns|antenna|antennae|bandana|headband|"
                     r"necklace|patch|tattoo|spots|stripes|wings)\b", re.I)


class Reject(Exception):
    pass


def _ssl_context():
    # python.org builds on macOS ship without a CA bundle; use the system one
    import ssl
    for f in ("/etc/ssl/cert.pem",):
        if os.path.exists(f):
            return ssl.create_default_context(cafile=f)
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


SSL = _ssl_context()


def http_json(url, body=None, timeout=10.0):
    req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"},
                                 method="GET" if body is None else "POST")
    with urllib.request.urlopen(req, timeout=timeout, context=SSL) as r:
        return json.loads(r.read())


def meshy_generate(jpeg_bytes, prompt, model, deadline):
    """Returns (image RGB array, info dict). Raises Reject on failure / timeout."""
    uri = "data:image/jpeg;base64," + base64.b64encode(jpeg_bytes).decode()
    t0 = time.time()
    try:
        j = http_json(MESHY, {"ai_model": model, "prompt": prompt, "reference_image_urls": [uri],
                              "aspect_ratio": "16:9"}, timeout=max(1.0, deadline - time.time()))
    except urllib.error.HTTPError as e:
        raise Reject(f"meshy submit {e.code}: {e.read()[:200].decode(errors='replace')}")
    tid = j["result"]
    t = {}
    while True:
        if time.time() > deadline:
            raise Reject("timeout waiting for the image model")
        time.sleep(0.5)
        try:
            t = http_json(f"{MESHY}/{tid}", timeout=5.0)
        except Exception as e:  # transient poll error: retry until the deadline
            continue
        if t.get("status") in ("SUCCEEDED", "FAILED", "CANCELED"):
            break
    if t["status"] != "SUCCEEDED":
        raise Reject(f"meshy {t['status']}: {json.dumps(t.get('task_error'))[:200]}")
    t_gen = time.time()
    url = t["image_urls"][0]
    with urllib.request.urlopen(url, timeout=max(1.0, deadline - time.time()), context=SSL) as r:
        img = np.asarray(Image.open(io.BytesIO(r.read())).convert("RGB"))
    return img, {"task": tid, "credits": t.get("consumed_credits"), "gen_s": round(t_gen - t0, 2),
                 "download_s": round(time.time() - t_gen, 2)}


def figure_box(orig):
    """Bounding box (paper units) of the user's drawing, robust to stray marks."""
    m, _, _ = ink_mask(orig, 3.0, border=6)
    ys, xs = np.nonzero(m)
    if len(xs) < 50:
        return None
    u = 1000.0 / orig.shape[1]
    return (np.percentile(xs, 1) * u, np.percentile(ys, 1) * u, np.percentile(xs, 99) * u, np.percentile(ys, 99) * u)


def describe_place(box, paper, fig, on_part):
    x0, y0, x1, y1 = box["x0"], box["y0"], box["x1"], box["y1"]
    W, H = paper["w"], paper["h"]
    pct = lambda v, d: int(round(100 * min(max(v / d, 0), 1)))
    region = (f"inside the region from {pct(x0, W)}% to {pct(x1, W)}% of the page width (measured from the left edge) "
              f"and from {pct(y0, H)}% to {pct(y1, H)}% of the page height (measured from the top edge)")
    if fig is None:
        return f"{region}, filling most of that region", "on the page"
    fx0, fy0, fx1, fy1 = fig
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    if on_part:
        rel = "on the existing figure, where it naturally belongs"
    elif x1 <= fx0 + 0.15 * (fx1 - fx0):
        rel = "to the left of the existing figure"
    elif x0 >= fx1 - 0.15 * (fx1 - fx0):
        rel = "to the right of the existing figure"
    elif y1 <= fy0 + 0.15 * (fy1 - fy0):
        rel = "above the existing figure"
    elif y0 >= fy1 - 0.15 * (fy1 - fy0):
        rel = "below the existing figure"
    else:
        rel = "next to the existing figure"
    size = "sized to fill most of that region" if not on_part else "sized to fit the figure"
    touch = "; it must not touch or overlap the existing drawing" if not on_part else \
        "; attach it to the existing drawing but do not redraw the existing lines"
    return f"{rel}, {region}, {size}{touch}", rel


def build_prompt(said, place):
    words = " / ".join(s.strip() for s in said if s.strip())
    return (f"Edit this image of a pencil drawing on paper. The person drawing said: \"{words}\". "
            f"Add the thing they asked for, {place}. Draw it the way THIS person draws, as if the same hand made "
            f"it: copy how they draw heads, faces, hair, bodies, arms, hands, legs and shoes, their proportions, how "
            f"loose or careful their lines are and how much detail they use. If they ask for something like an "
            f"existing figure, copy that figure's features closely. Draw ONLY the new addition, in continuous red "
            f"pen lines of a single even weight: no shading, no solid fill, no other colours, no text. Leave everything that is already on the page exactly as it is: do not "
            f"move, redraw, resize, restyle, recolour or erase any existing grey pencil line, and keep the paper, "
            f"framing and position identical. Only add the new red lines.")


def is_on_part(said, box, fig):
    """True when the new lines belong ON the existing figure (hat, teeth, buttons...):
    the words name a part/accessory AND the box touches the figure (grown by 20%),
    or the box lies mostly on the figure whatever the words."""
    if fig is None:
        return False
    def inter(f):
        ix = max(0, min(box["x1"], f[2]) - max(box["x0"], f[0]))
        iy = max(0, min(box["y1"], f[3]) - max(box["y0"], f[1]))
        return ix * iy
    area = max(1e-6, (box["x1"] - box["x0"]) * (box["y1"] - box["y0"]))
    gx, gy = 0.2 * (fig[2] - fig[0]), 0.2 * (fig[3] - fig[1])
    grown = (fig[0] - gx, fig[1] - gy, fig[2] + gx, fig[3] + gy)
    if ON_PART.search(" ".join(said)) and inter(grown) > 0:
        return True
    return bool(inter(fig) / area > 0.5)


def upgrade(req, model, info=None):
    """Runs one request. Fills `info` (for the log) as it goes, also when it rejects."""
    T0 = time.time()
    deadline = T0 + DEADLINE_S
    ms = {}
    info = {} if info is None else info
    jpeg = base64.b64decode(req["page_jpeg"])
    orig = np.asarray(Image.open(io.BytesIO(jpeg)).convert("RGB"))
    paper = req.get("paper") or {"w": 1000, "h": round(orig.shape[0] * 1000 / orig.shape[1])}
    said = req.get("said") or []
    box = req["box"]
    if not said:
        raise Reject("no request words")
    fig = figure_box(orig)
    on_part = bool(is_on_part(said, box, fig))
    place, rel = describe_place(box, paper, fig, on_part)
    prompt = build_prompt(said, place)
    scan = clean(orig)
    buf = io.BytesIO()
    Image.fromarray(scan).save(buf, "JPEG", quality=92)
    ms["prep"] = int((time.time() - T0) * 1000)
    info.update({"prompt": prompt, "on_part": on_part})
    t = time.time()
    try:
        gen, minfo = meshy_generate(buf.getvalue(), prompt, model, deadline - PROCESS_RESERVE_S)
    finally:
        ms["image_model"] = int((time.time() - t) * 1000)
    info.update(minfo)
    if SAVE_DIR:
        Image.fromarray(gen).save(os.path.join(SAVE_DIR, re.sub(r"[^\w.-]", "_", str(req.get("id", "x")))[:60]
                                               + f"-{int(T0)}.jpg"), quality=88)
    t = time.time()
    out, dbg = pipeline.process_arrays(orig, gen)
    ms["register_trace"] = int((time.time() - t) * 1000)
    reg = out["registration"]
    info["registration"] = {k: (round(v, 3) if isinstance(v, float) else v) for k, v in reg.items()}
    info["mode"] = out.get("mode")
    if not out["accept"]:
        raise Reject(f"registration gate: median {reg['median']:.2f}u, cover3 {reg['cover3']:.0%}, "
                     f"worst part {reg['worst_part_median'] or 0:.2f}u, worst shift {reg.get('worst_part_shift') or 0:.2f}u")
    if out.get("mode") != "red":
        raise Reject("model did not draw in red (cannot isolate the new lines safely)")
    strokes = out["strokes"]
    if not strokes:
        raise Reject("no new lines found")
    on_orig = out["stats"]["on_original"]
    info["on_original"] = on_orig
    if not on_part and on_orig > 0.02:
        raise Reject(f"new drawing overlaps the existing one ({on_orig:.0%} of its ink)")
    # placement: the new drawing's centre must lie in the requested box grown by half its size
    new = dbg["new"]
    ys, xs = np.nonzero(new)
    cx, cy = xs.mean() / pipeline.PPU, ys.mean() / pipeline.PPU
    bw, bh = box["x1"] - box["x0"], box["y1"] - box["y0"]
    gx, gy = max(0.5 * bw, 40), max(0.5 * bh, 40)
    nb = [float(xs.min() / pipeline.PPU), float(ys.min() / pipeline.PPU), float(xs.max() / pipeline.PPU), float(ys.max() / pipeline.PPU)]
    info["new_box"] = [round(v, 1) for v in nb]
    if not (box["x0"] - gx <= cx <= box["x1"] + gx and box["y0"] - gy <= cy <= box["y1"] + gy):
        raise Reject(f"drawn in the wrong place: centre ({cx:.0f},{cy:.0f}) vs box {box}")
    ms["total"] = int((time.time() - T0) * 1000)
    return {"ok": True, "strokes": strokes, "ms": ms, "model": model,
            "registration": {"median_u": round(reg["median"], 2), "p90_u": round(reg["p90"], 2),
                             "worst_part_shift_u": round(reg.get("worst_part_shift") or 0, 2)},
            "new_box": info["new_box"]}, info


class Handler(BaseHTTPRequestHandler):
    server_version = "DrawUpgrade/1"
    model = "gpt-image-2-5-flare"

    def log_message(self, *a):
        pass

    def send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path.rstrip("/") == "/health":
            return self.send(200, {"ok": True})
        self.send(404, {"ok": False, "reason": "not found"})

    def do_POST(self):
        if self.path.rstrip("/") != "/upgrade":
            return self.send(404, {"ok": False, "reason": "not found"})
        if not hmac.compare_digest(self.headers.get("X-DC-Token", ""), TOKEN):
            print("[upgrade] rejected: bad token from", self.client_address[0], flush=True)
            return self.send(403, {"ok": False, "reason": "bad token"})
        T0 = time.time()
        rid, info, resp = "?", {}, None
        model = self.model
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n))
            rid = str(req.get("id", "?"))[:80]
            model = req.get("model") or self.model
            resp, _ = upgrade(req, model, info)
        except Reject as e:
            resp = {"ok": False, "reason": str(e)}
        except Exception as e:
            traceback.print_exc()
            resp = {"ok": False, "reason": f"error: {type(e).__name__}: {e}"[:300]}
        total = int((time.time() - T0) * 1000)
        resp.setdefault("ms", {})["total"] = total
        try:
            self.send(200, resp)
        except Exception:
            pass
        rec = {"at": time.strftime("%Y-%m-%dT%H:%M:%S"), "source": "server", "id": rid, "model": model,
               "ok": resp["ok"], "reason": resp.get("reason"), "ms": resp.get("ms"), "credits": info.get("credits"),
               "task": info.get("task"), "gen_s": info.get("gen_s"), "on_part": info.get("on_part"),
               "on_original": info.get("on_original"), "registration": info.get("registration"),
               "new_box": info.get("new_box"), "strokes": len(resp.get("strokes", [])), "prompt": info.get("prompt")}
        with _log_lock:
            with open(LOG, "a") as f:
                f.write(json.dumps(rec) + "\n")
        print(f"[upgrade] {rid} ok={resp['ok']} ms={total}" + ("" if resp["ok"] else f" reason={resp['reason']}"), flush=True)


if __name__ == "__main__":
    # Local-only by default. The phone needs `--host 0.0.0.0` (LAN). That exposes an
    # endpoint which spends Meshy credits to anyone on the network: start it that way
    # only deliberately, on a trusted network.
    port, host = 8787, "127.0.0.1"
    args = sys.argv[1:]
    if "--port" in args:
        port = int(args[args.index("--port") + 1])
    if "--host" in args:
        host = args[args.index("--host") + 1]
    if "--model" in args:
        Handler.model = args[args.index("--model") + 1]
    if "--save-dir" in args:
        SAVE_DIR = args[args.index("--save-dir") + 1]
        os.makedirs(SAVE_DIR, exist_ok=True)
    srv = ThreadingHTTPServer((host, port), Handler)
    srv.daemon_threads = True
    print(f"upgrade server on {host}:{port}, model {Handler.model}", flush=True)
    srv.serve_forever()
