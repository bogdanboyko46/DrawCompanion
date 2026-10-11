# Image-model outlines: mapping, extraction, tracing

The plan is a hybrid. Claude's vector outline appears in about 3 s. When an image model's picture is ready, strokes traced from it replace that outline. This folder covers the second half, offline and measured: register the generated bitmap onto the page photo, isolate the new lines, and trace them into the app's stroke format.

```
page photo ──prep.py──▶ "clean scan" ──gen.mjs (Meshy)──▶ generated bitmap
                                                              │
page photo ─────────────────────────────▶ pipeline.py ◀──────┘
     register.py   generated→page transform + accept/reject (paper units)
     ink.py        pencil / red-pen ink, grid-aware
     trace.py      skeleton → graph → chains → cubic Béziers, ordered
     ──▶ [{"role","weight":"medium","d":"M x y C …"}]   (page 1000 wide)
```

## Recommendation

| | |
|---|---|
| **Model** | `gpt-image-2` with `aspect_ratio: "16:9"`: **22 s** median (20–25 s), 12 credits. It kept the user's drawing in every run and followed placement best. Use `gpt-image-2-5-flare` (same settings) when speed matters: **14.5 s** (13.6–15.1 s), same price and similar line quality, but it twice drew the new object touching or overlapping the figure. |
| **Input** | the "clean scan" from `prep.py clean`: white paper, neutral grey pencil, no grid, no shadow. |
| **Prompt** | the `red` template below: **draw only the new object in red pen**. |
| **Extraction** | the new lines are the red ink, so no diff against the original is needed. The pencil-diff path is kept as a fallback. |
| **Gate** | accept only if registration passes: median ≤ 1.5 u, ≥ 80 % of the original line within 3 u, no part > 3 u median, and **no part displaced > 1.5 u** (see "Mapping"). |
| **End to end** | ~24 s on gpt-image-2 (upload ~1 s + 21 s generation + download + ~1 s processing), ~16 s on flare, ~9 s on `nano-banana`. |

**The prompt** (`prompts.mjs`, `red`; `{obj}`, `{where}` and `{short}` are filled in per request):

> Edit this image of a pencil drawing on paper. Add {obj} {where}. Draw ONLY the new {short} with clean, smooth, continuous red pen lines: simple line art with a single even line weight, no shading, no hatching, no fill, no other colours. Leave everything that is already on the page exactly as it is: do not move, redraw, resize, restyle, recolour or erase any existing grey pencil line, and keep the paper, framing and position identical. Only add the new red lines.

Example: `{where}` = "on the empty paper to the LEFT of the figure (the cat should be about as tall as the figure's body and must not touch or overlap him)".

Why red: the projected strokes are what the user sees, so the bitmap's style does not matter. Colour-coding turns extraction from "subtract two pencil drawings that never quite align" into a colour threshold. It holds up when the model slightly re-renders the old lines or the shading, and when the new lines touch old ones (a hat on the hair, teeth in a smile). Every model obeyed it and left the grey drawing grey, except for redrawing the smile in the teeth request (see Risks).

## Results (29 images: 27 generated here, plus the 2 earlier cat tests)

Contact sheets. Each row shows the traced strokes on the **original photo** and a zoom. Red is a contour stroke, orange a detail, blue dots mark stroke starts with their drawing order.

- `results/contact-gpt-image-2-red.jpg`: 8 requests on gpt-image-2 (recommended setup)
- `results/contact-gpt-image-2-5-flare-red.jpg`: the same 8 on flare
- `results/contact-cat-all-models.jpg`: the cat on every model and prompt variant, including the rejected ones
- `results/contact-pencil-diff.jpg`: the pencil-style prompt, extracted by diff
- `results/runs/<run>.json`: strokes and all metrics per run. `results/runs/summary.json` holds the table below. Run `batch.py` to recreate the 6-panel debug PNGs.
- `generated/`: every bitmap the models returned. `calls.jsonl`: every API call with prompt, timing and credits.

### Per model

| model (16:9 unless noted) | gen time | credits | kept the drawing? | registration residual (median / p90, paper units) | notes |
|---|---|---|---|---|---|
| gpt-image-2 | **22.0 s** (n=12) | 12 | yes, 13/13 | 0.46–0.57 / 0.8–1.6 | best placement and line quality |
| gpt-image-2, 1:1 (default) | 33.2 s | 12 | yes | 0.54 / 1.33 | 1:1 is ~11 s slower for nothing |
| gpt-image-2-5-flare | **14.5 s** (n=9) | 12 | yes, 8/8 | 0.48–0.63 / 0.8–2.4 | cat overlapped the figure's ear (4 % of its ink on the figure), dog touched the flag |
| nano-banana-2 | 11.9 s (n=3) | 6 | yes in all 3 runs here; the earlier cat test **stretched the figure** and is rejected | 0.41–0.44 / 0.85–0.93 | odd anatomy (standing cat, stick legs). With the photo as input it zoomed and cropped the page (handled by registration) |
| nano-banana | **7.8 s** (n=1) | 3 | yes | 0.47 / 0.94 | cheapest and fastest. The cat came out bigger than asked, with a ground line |
| nano-banana-pro | 43.0 s (n=1) | 9 | yes | 0.42 / 0.88 | too slow |

Spend: 27 logged calls, **294 credits**, about $6 at Meshy's ~$0.02/credit. The account balance fell 824 → 494 during the session; the other ~36 credits were not from these calls.

### Grid, clean scan, "alone"

- **Grid baked in:** every model *kept* the grid when it was in the input (gpt-image-2 kept it blue; nano-banana-2 drew it as grey lines in the earlier test). Sending the clean scan gives cleaner bitmaps (no grid or shadow for the model to reproduce) at the same speed. The extractor copes with both: `ink.py` cancels blue grid lines, and grey grid lines are removed as long axis-aligned runs on known grid positions.
- **"Alone" variant** (erase the drawing, draw only the new object at the same place): flare complied, but nothing is left to register against. The result is correctly **rejected** (0 % coverage). Its placement could only be trusted on faith in the frame, so it is not recommended.
- The pencil-style prompt plus diff extraction works for objects beside the figure (cat: 16 strokes, clean). For edits touching the existing lines it is fragile: in the teeth case the model redrew part of the smile 5–8 u off, which the diff reads as "new" fragments. Red is much more robust.

### Every run

| run | accept | mode | median u | p90 u | cover3 | worst part u | worst shift u | strokes | cubics | gen s | proc ms |
|---|---|---|---|---|---|---|---|---|---|---|---|
| p1-bike / red / flare | yes | red | 0.63 | 1.30 | 94% | 0.64 | 0.27 | 11 | 36 | 14.6 | 2017 |
| p1-bike / red / gpt-image-2 | yes | red | 0.52 | 1.49 | 93% | 0.63 | 0.36 | 12 | 55 | 23.9 | 2546 |
| p1-house / red / flare | yes | red | 0.56 | 1.39 | 94% | 0.68 | 0.75 | 10 | 48 | 15.0 | 1761 |
| p1-house / red / gpt-image-2 | yes | red | 0.57 | 1.57 | 92% | 0.67 | 0.27 | 8 | 38 | 22.0 | 1450 |
| p2-cat / alone / flare | **REJECT** | red | 159 | 246 | 0% | 165 | – | 0 | 0 | 14.0 | 2001 |
| p2-cat / first test / gpt-image-2 1:1 | yes | diff | 0.52 | 1.26 | 96% | 0.51 | 0.45 | 16 | 38 | ~33 | 2555 |
| p2-cat / first test / nano-banana-2 1:1 | **REJECT** | diff | 2.19 | 11.1 | 60% | 5.38 | 5.77 | – | – | ~12 | 3407 |
| p2-cat / pencil / gpt-image-2 | yes | diff | 0.53 | 0.80 | 97% | 0.53 | 0.08 | 16 | 39 | 21.9 | 1930 |
| p2-cat / pencil / gpt-image-2 1:1 photo | yes | diff | 0.54 | 1.33 | 94% | 0.54 | 0.07 | 19 | 43 | 33.2 | 1702 |
| p2-cat / pencil / nano-banana-2 | yes | diff | 0.42 | 0.85 | 98% | 0.41 | 0.19 | 17 | 51 | 11.9 | 1752 |
| p2-cat / pencil / nano-banana-2 1:1 photo | yes | diff | 0.44 | 0.93 | 98% | 0.43 | 0.25 | 12 | 67 | 11.3 | 2247 |
| p2-cat / red / flare | yes | red | 0.62 | 2.39 | 92% | 0.64 | 0.22 | 12 | 42 | 13.6 | 1915 |
| p2-cat / red / gpt-image-2 | yes | red | 0.51 | 0.90 | 97% | 0.49 | 0.05 | 11 | 38 | 21.8 | 1280 |
| p2-cat / red / gpt-image-2 photo | yes | red | 0.46 | 1.35 | 93% | 0.46 | 0.20 | 12 | 41 | 24.8 | 1367 |
| p2-cat / red / nano-banana-2 | yes | red | 0.42 | 0.86 | 98% | 0.45 | 0.24 | 19 | 69 | 12.0 | 1772 |
| p2-cat / red / nano-banana-pro | yes | red | 0.42 | 0.88 | 98% | 0.42 | 0.15 | 7 | 58 | 43.0 | 891 |
| p2-cat / red / nano-banana | yes | red | 0.47 | 0.94 | 96% | 0.47 | 0.10 | 24 | 63 | 7.8 | 1489 |
| p2-dog / red / flare | yes | red | 0.48 | 0.81 | 98% | 0.48 | 0.09 | 7 | 38 | 14.5 | 1138 |
| p2-dog / red / gpt-image-2 | yes | red | 0.46 | 0.89 | 97% | 0.52 | 0.18 | 11 | 38 | 22.1 | 2434 |
| p3-hat / pencil / gpt-image-2 | yes | diff | 0.56 | 0.89 | 98% | 0.57 | 0.27 | 3 | 8 | 23.2 | 1383 |
| p3-hat / red / flare | yes | red | 0.58 | 1.31 | 97% | 0.60 | 0.78 | 3 | 9 | 14.7 | 2004 |
| p3-hat / red / gpt-image-2 | yes | red | 0.46 | 0.92 | 98% | 0.53 | 0.09 | 3 | 10 | 20.3 | 1420 |
| p3-sun / red / flare | yes | red | 0.55 | 0.91 | 99% | 0.55 | 0.48 | 9 | 11 | 14.5 | 1199 |
| p3-sun / red / gpt-image-2 | yes | red | 0.57 | 0.90 | 98% | 0.59 | 0.26 | 9 | 10 | 22.0 | 1150 |
| p3-teeth / pencil / gpt-image-2 | yes | diff | 0.53 | 1.08 | 97% | 1.61 | 0.92 | 4 | 7 | 21.4 | 1930 |
| p3-teeth / red / flare | yes | red | 0.49 | 0.83 | 98% | 0.62 | 0.21 | 3 | 7 | 14.4 | 1023 |
| p3-teeth / red / gpt-image-2 | yes | red | 0.57 | 0.85 | 98% | 0.58 | 0.40 | 4 | 9 | 21.0 | 996 |
| p3-tree / red / flare | yes | red | 0.50 | 1.01 | 98% | 0.61 | 0.34 | 6 | 27 | 15.1 | 1112 |
| p3-tree / red / gpt-image-2 | yes | red | 0.55 | 0.83 | 99% | 0.58 | 0.20 | 4 | 43 | 22.7 | 1184 |

How to read the residual columns: for every pixel of the user's own pencil skeleton, the distance in paper units to the nearest pencil skeleton in the registered generated image. *cover3* is the share within 3 u. *Worst part* is the worst per-part median and *worst shift* the worst per-part displacement. Parts the request was about (the smile, for teeth) are excluded from the verdict, since the model may redraw them. *proc ms* is Python/OpenCV on a laptop for the whole pipeline. The p90 is inflated by faint original strokes the model drew a little differently; the true mapping error is far smaller (next section).

## Mapping (register.py)

A ground-truth test (`synth.py`) re-renders each page with a known random transform: 75–100 % scale into a 1024² frame, ±3° rotation, ±6 % aspect squash, mild perspective, ±40 px shift, letterbox padding, JPEG q80. Then it registers. **True error of the recovered transform at the drawing's pixels: median 0.16 u, worst single pixel 2.8 u** (15 renders), comfortably under the 3 u target. The same renders with a **local** warp of the figure test the reject gate:

| local warp of the figure's head | true mapping error it causes (median) | rejected |
|---|---|---|
| none | 0.16 u | 0/15 (all accepted) |
| shift 3 u | 1.1 u | 6/15 |
| shift 6 u | 2.1 u | **15/15** |
| stretch 6 u | 1.5 u | **15/15** |
| stretch 12 u (nano-banana style) | 2.8 u | **15/15** |

Every warp whose mapping error approaches the 3 u target is rejected. Of the 3 u shifts (error ~1 u, under the target) 9/15 still pass, which is the intended tolerance. On real images, clean outputs show a worst part shift of 0.05–0.78 u. The stretched nano-banana-2 cat test shows 5.8 u.

Algorithm:
1. **Ink** (both images, `ink.py`). Divide by a local paper estimate (grey closing, kernel 3× line width, Gaussian blur) and take darkness in the **blue channel**: graphite darkens every channel, blue grid ink barely darkens blue. Grid lines are cancelled: a closing along each axis (kernel 15× line width) that comes out bluish **and** stays bright in blue is the local background, so pencil crossing or running along a grid line is measured against the grid's own colour. Penalties apply for leftover blue (labels) and for red. Hysteresis threshold (high = clamp(0.42 × p99.9, 0.12, 0.2), low = 0.6 × high), then drop components < 3·w² px. Paper mask: background luminance > 0.6 × median, eroded. On the original, ignore a 6 px border (the sheet's edge).
2. **Skeletons**. The original skeleton P has ~1–2k points. The generated skeleton gets a distance transform *with labels*, so each pixel knows its nearest skeleton pixel in O(1).
3. **Coarse**. FFT normalised cross-correlation of the blurred original-ink patch (its bounding box) against the blurred generated ink at 320 px, over 36 log-spaced scales (0.4–2.5× the fit-width scale) × 3 aspect squashes (0.92, 1, 1.08). Keep the 6 best distinct (scale, position) candidates (~150 ms).
4. **Fine**. For each candidate, trimmed ICP from original to generated (new ink is just an outlier, since only original→generated distances are used). The schedule is similarity at gates 12/8/6 u, affine at 6/4 u, homography at 4/3/2.5/2.5 u, 4 iterations each. Similarity uses closed-form Umeyama, affine least squares, homography DLT. A stage is kept only if it lowers the truncated chamfer cost (mean of min(d, 5 u)) **and** stays plausible: Jacobian anisotropy ≤ 1.2 and scale ratio across the drawing's bounding box ≤ 1.08. That guard stops the classic chamfer collapse, where everything maps onto one dense patch. Pick the candidate with the lowest cost.
5. **Verdict**. Residuals in paper units for every original skeleton point. For each connected part of the original drawing, a translation-only ICP from the global fit gives that part's systematic **shift**. Accept iff median ≤ 1.5 u, cover3 ≥ 80 %, worst part median ≤ 3 u, and worst part shift ≤ 1.5 u. Parts within 8 u of the new red ink count as "edited" and are left out of the verdict.

## Extraction (pipeline.py)

Work on a canvas at **2 px per paper unit** (the generated image has ~1.1 px/u). Warp the generated ink into it with the inverse of the canvas→original→generated transform.
- Valid area = original paper mask ∩ generated paper mask, minus 6 px of the generated frame. Models sometimes crop or zoom, so part of the page can fall outside their frame; the frame edge is not drawing.
- **Red mode** (used when the generated image has > 200 px of red ink): new = red ink (`ink.red_score`, R minus mean(G, B), normalised by paper).
- **Diff mode** (fallback): new = pencil ink farther than 5 u from the original skeleton, minus long axis-aligned runs on the photo's grid lines.
- Component clean-up removes:
  - specks (span < 6 u or area < 12 u²)
  - in diff mode, slivers that never leave the 8 u halo of an original line
  - remnants of grid labels
  - pieces lying ≥ 80 % within 12 u of the valid area's edge (the sheet edge)
- `on_original` reports the share of new ink lying on the user's lines. It is ~0 for "next to him" requests and catches a model that drew over the figure.

## Tracing (trace.py)

On the extracted mask (canvas px; every length below is in paper units):
1. Close 3×3, fill holes < 12 u², then **skeletonize** (Zhang–Suen / skimage).
2. **Graph**. Node = a junction *cluster* (8-connected group of pixels with ≥ 3 neighbours) or an endpoint. Edge = the pixel path between nodes, walked preferring 4-neighbours. Pure cycles become loops.
3. **Prune spurs**. Repeatedly remove an endpoint→junction edge shorter than **5 u** while that junction has ≥ 3 edges.
4. **Join at junctions**. A junction left with exactly 2 edges is a pass-through and is always joined (a sharp tip such as a cat's ear stays one stroke; the corner survives the fit). Otherwise pair edges greedily by straightest continuation: outgoing directions averaged over 8 u, turn ≤ 50°. Walk the pairings into polylines. A chain end that stops at a junction is extended to the junction centre, so T-joints touch.
5. **Bridge gaps** between open ends ≤ **6 u** apart that point at each other (≤ 40° each). Ends ≤ 2.5 u apart join at any angle unless they retrace each other.
6. **Reach**. An open end that stops short of *another* line (≤ 10 u) is extended to it, but only if at most 2.5 u of the connecting segment is blank paper. That fixes grid-crossing and skeleton-retraction gaps without inventing lines (it never joins an eye to a smile).
7. (Diff mode) **Snap** ends that stop within 13 u of an original line, pointing at it, onto that line. The 5 u halo cut them there.
8. Drop lines < 8 u. Resample at 1 u. Find **corners** where the turn over ±5 samples is ≥ 50° (non-maximum suppressed, 6 samples apart). Gaussian-smooth (σ 1.6 u, ends pinned, loops circular).
9. **Fit cubics** per corner-to-corner piece with Schneider's algorithm: chord-length parameters, end tangents taken 4 u in, least-squares handle lengths, 4 Newton reparameterisations, split at the worst point while the error is > **0.8 u**. A piece within 0.6 u of its chord becomes one straight cubic (sun rays and house walls come out truly straight).
10. **Order and roles**. *Detail* means a stroke shorter than max(20 u, 3.5 % of the total length) whose bounding box is under 30 % of the drawing's diagonal; everything else is *contour*. Contours come first, longest first. Details follow as a nearest-neighbour tour from where the last contour ended. Open strokes start at their upper-left end. Closed shapes get `Z`.

Typical output: cat 11–16 strokes and ~40 cubics, dog 7–11, bike 11–12, house 8–10, tree 4–6, sun 9 (circle + 8 rays), hat 3, teeth 3–4.

## Porting to the iPhone

Everything is plain image processing with no learned parts, so it can run **on device**. In Python/OpenCV on a laptop the whole thing takes 1.0–2.5 s, mostly in Python-level loops (graph walk, per-part ICP) and the 2 px/u canvas. `profile.py` breaks it down: ink masks ~250 ms, coarse search ~150 ms, `register()` ~600 ms. Estimate for Swift on an A16-class phone with vImage/Accelerate:

| step | how | est. |
|---|---|---|
| ink score + hysteresis, 1536×864 | vImage min/max filters (separable), float math | 30–60 ms |
| coarse search, 108 NCCs at 320 px | vDSP FFT, or downscale to 160 px and refine | 40–100 ms |
| skeleton + distance transform with labels | Zhang–Suen on ink bbox; 2-pass Felzenszwalb EDT | 15–30 ms |
| ICP, 6 candidates × 9 stages × 4 iters × ~1.5k pts | SIMD, 2×2 / 3×3 / 8×8 solves | 10–20 ms |
| warp + extraction on 2000×900 canvas | vImage warp (or work on the new-ink bbox only) | 20–40 ms |
| trace (graph, chains, fit) | plain Swift | 5–15 ms |
| **total** | | **~150–300 ms** |

Against ~20 s of generation this is negligible. Running it server-side next to the Meshy call (this Python as is) also works, and keeps the Meshy key off the phone. **Recommendation: put the Meshy call and this pipeline on a small server endpoint** (key safety, one round trip, no port needed to ship). Port to Swift only if there is no backend: the algorithm above is complete, and every constant is in the code with its unit.

## Risks and failure cases seen

- **Models do redraw the existing drawing.** The earlier nano-banana-2 cat test enlarged and stretched the figure; it is caught (worst shift 5.8 u) and rejected. In that case keep Claude's outline. All 26 new generations here (clean scan or photo, red or pencil prompt) passed the gate; nano-banana-2 has failed it before.
- **Edits that touch existing lines.** For "teeth", both GPT models redrew the whole mouth in red, 3–5 u off the user's smile, so the traced mouth sits slightly beside the real smile. The registration is right; the model moved the mouth. Possible mitigations: drop red strokes running parallel within ~6 u of an original line, or ask "do not redraw the smile".
- **Placement obedience.** Flare put the cat over the figure's ear and the dog against his flag. `on_original` flags it (4 % here); consider rejecting or re-prompting above ~2 %.
- **Off-page.** Objects near the top edge (hat, tree crown) can run into the sheet's edge and get clipped there. That is true to the page, but the stroke ends open.
- **Faint pencil** (page-1 is dim): the original skeleton has gaps, so fewer registration points (still ~1k) and slightly higher p90. Registration was fine on all three pages.
- **Shading or filled areas** (a black nose): the skeleton of a filled blob is a short medial line, which traces as a small detail stroke. Fine for noses; a heavily shaded output would trace poorly. The red/line-art prompt prevented this in every run.
- **The "alone" prompt** removes what registration needs: nothing can verify the placement.
- **Grid labels or page edge** reproduced by a model are filtered (label zones, frame-edge zone, long grid runs). A model that redraws the grid *shifted* would leave grid lines in diff mode only; red mode is immune.
- **Queue limit**: Meshy rejected more than ~11 concurrent tasks (429 NoMorePendingTasks). One request per user at a time is fine.

## Reproduce

```bash
PY=python   # with numpy, opencv-python-headless, scikit-image, scipy, Pillow
$PY eval/imagegen/prep.py eval/photos/page-2.jpg /tmp/prep/page-2          # -nogrid.jpg, -clean.jpg
node --env-file=.env eval/imagegen/run.mjs /tmp/gen /tmp/prep p2-cat:red:gpt-image-2:clean:16x9   # case:prompt:model:input:aspect
$PY eval/imagegen/pipeline.py eval/photos/page-2.jpg /tmp/gen/p2-cat__red__gpt-image-2__clean__16x9.png /tmp/out
$PY eval/imagegen/batch.py eval/imagegen/generated eval/imagegen/results/runs                       # all runs, offline
$PY eval/imagegen/sheet.py eval/imagegen/results/runs eval/imagegen/results/contact-x.jpg __red__gpt-image-2__
$PY eval/imagegen/synth.py 5                                                                        # ground-truth registration test
$PY eval/imagegen/profile.py eval/photos/page-2.jpg eval/imagegen/generated/p2-dog__red__gpt-image-2__clean__16x9.jpg
```
