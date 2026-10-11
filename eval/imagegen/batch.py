# Runs the pipeline over every generated image in a folder.
#   python batch.py <gen_dir> <results_dir> [filter-substring]
# File names: <case>__<variant>__<model>__<photo>__<aspect>.png (see run.mjs).
# Writes <results_dir>/<tag>.json + .png and <results_dir>/summary.json.
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pipeline

here = os.path.dirname(os.path.abspath(__file__))
cases = {"p1": "page-1", "p2": "page-2", "p3": "page-3"}
gen_dir, res_dir = sys.argv[1:3]
filt = sys.argv[3] if len(sys.argv) > 3 else ""
os.makedirs(res_dir, exist_ok=True)
calls = {}
cl = os.path.join(here, "calls.jsonl")
if os.path.exists(cl):
    for line in open(cl):
        r = json.loads(line)
        calls[r["tag"]] = r
summary_path = os.path.join(res_dir, "summary.json")
summary = json.load(open(summary_path)) if os.path.exists(summary_path) else {}
for f in sorted(os.listdir(gen_dir)):
    if not f.endswith((".png", ".jpg")) or filt not in f:
        continue
    tag = f[:-4]
    page = cases[tag.split("-")[0]]
    out, dbg = pipeline.process(os.path.join(here, "..", "photos", f"{page}.jpg"), os.path.join(gen_dir, f))
    json.dump(out, open(os.path.join(res_dir, tag + ".json"), "w"), indent=1)
    pipeline.panels(out, dbg, tag).save(os.path.join(res_dir, tag + ".png"))
    r = out["registration"]
    c = calls.get(tag, {})
    summary[tag] = {"accept": out["accept"], "mode": out.get("mode"), "median": round(r["median"], 2), "p90": round(r["p90"], 2),
                    "cover3": round(r["cover3"], 3), "worst_part": round(r["worst_part_median"] or 0, 2), "worst_shift": round(r.get("worst_part_shift") or 0, 2), "edited_parts": r.get("edited_parts"),
                    "strokes": out["stats"]["strokes"], "cubics": out["stats"]["segments"], "on_original": out["stats"]["on_original"], "proc_ms": out["ms"]["total"],
                    "gen_s": c.get("s", {}).get("total"), "credits": c.get("credits"), "size": list(dbg["gen"].shape[1::-1])}
    print(tag, json.dumps(summary[tag]))
json.dump(summary, open(summary_path, "w"), indent=1)
