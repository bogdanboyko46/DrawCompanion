# Headset session status

**Branch: `claude/fervent-turing-1v3ob4`** (based on `ar/headset`)

## Done (CI status per item below)

1. **Lens pre-distortion.** The scene (camera + outline) is rendered once into a square "eye texture" covering ±40° around the lens axis, then drawn into each half of the screen through a barrel pre-distortion shader (`distortFragment`, radial k1/k2 model). Cardboard v1 defaults: k1 0.441, k2 0.156, screen-to-lens 42 mm, lens separation 60 mm, 460 ppi. Outside each lens's field is black with a soft edge. Math in `Core/HeadsetOptics.swift`, tested in `CoreTests/HeadsetTests.swift` (incl. "a straight line in what the eye sees is bowed on screen and comes back straight through the lens").
2. **Eye layout / IPD / zoom** as settings (UserDefaults keys below). Eye texture is sized to match screen sharpness at the lens center (~1280 px on an iPhone 17 Pro) and mipmapped so lines don't shimmer at the edges.
3. **Line quality.** Scene pass is 4x MSAA (memoryless MSAA color + stencil, resolved into the eye texture or the screen). Strokes are instanced round-capped capsules with exact per-sample coverage (`[[sample_mask]]`), so round joins/caps and smooth edges at any width. A per-stroke stencil means overlapping pieces of a translucent stroke don't darken. Dashes (construction, shading) are cut on the CPU into capsules and continue around corners (`Core/HeadsetStrokes.swift`, tested). Hand mask fade kept.
4. **Smoothness.** `preferredFramesPerSecond = 120`. A frame is drawn only when ARKit has a new image or something is animating (fade-out, draw-on), so camera frames show at the next 120 Hz refresh. Capsule data goes into a 3-deep ring of reused `MTLBuffer`s guarded by a semaphore; scratch arrays and render pass descriptors are reused; render targets are recreated only on size change. The view matrix inverse is computed once per frame instead of once per point.
5. **Draw-on fade-in.** Each new stroke draws itself along its length over 0.45 s (ease-out) while fading in. Strokes are matched by their path data, so drift-correction moves don't replay it.
6. **Status dot / problem text** in the headset now sit inside each lens's visible field (placed through the lens model), not at the screen edge where the black border would hide them.

## What to look for on the phone
- Headset view: each eye is a rounded-square window with black around it. In the viewer, straight paper edges should look straight up to the edge of the field. If they bow outward (pincushion), raise `headset.k1`; if inward, lower it. Toggle `headset.correctsDistortion` to compare.
- If the two images don't fuse comfortably, adjust `headset.lensSeparationMM` (the viewer's lens spacing).
- Outline lines should be smooth (no stair steps), dashes clean, translucent construction lines even where they cross themselves.
- New strokes draw themselves on as they stream in.
- Console: `[DC] headset: …` (layout, once per change) and `[DC] render: N fps drawn, X ms CPU per frame` every 10 s. Expect ~60 fps drawn (camera rate), more during animations once 120 Hz is enabled (request below).

## Settings (UserDefaults keys, for the UX session's Settings screen)

All Doubles unless noted; unset = default. Values are clamped to sane ranges (`HeadsetOptics.limits`). Changes apply live (the renderer re-reads every 0.5 s).

| Key | Default | Meaning | Range |
|---|---|---|---|
| `headset.zoom` | 1.1 | Each eye's field (top to bottom) shows 1/zoom of the camera image height. 1 = image just fills the field; bigger = closer | 0.5–4 |
| `headset.lensSeparationMM` | 60 | Distance between the two eye images' centers (viewer lens spacing / IPD) | 40–80 |
| `headset.verticalOffsetMM` | 0 | Lens centers above (+) / below (−) the screen's middle | −20–20 |
| `headset.k1` | 0.441 | Lens distortion, 2nd order | −0.5–1.5 |
| `headset.k2` | 0.156 | Lens distortion, 4th order | −0.5–1.5 |
| `headset.screenToLensMM` | 42 | Screen to lens distance | 20–80 |
| `headset.fieldOfViewDegrees` | 40 | Half-angle visible per eye | 20–60 |
| `headset.pixelsPerInch` | 460 | Screen density | 200–700 |
| `headset.correctsDistortion` (Bool) | true | Lens pre-distortion on/off | |

Keys are also in code: `HeadsetOptics.Key.*`. Suggested Settings UI: sliders for zoom and lens separation, a "lens correction" toggle; the rest under "Advanced".

Note on zoom: the old `Renderer.headsetZoom = 1.6` (of the screen half's height) is roughly `headset.zoom` 1.5 in the new terms. The new default 1.1 is a bit wider, which is easier for hand-eye coordination; raise it if the lead prefers the old look.

## Requests for the lead
1. **120 Hz:** add `INFOPLIST_KEY_CADisableMinimumFrameDurationOnPhone = YES;` to both build configurations of the DrawCompanionAR target in `ios/DrawCompanionAR.xcodeproj/project.pbxproj` (next to the other `INFOPLIST_KEY_` lines). Without it iPhones cap the app at 60 Hz.
2. **Per-frame allocation in `AppModel.scene()`:** with drift correction on it builds a new strokes array (and new points arrays) every frame. Cheaper: cache the mapped strokes and only rebuild when `outline` or `referenceToCurrent` changes (e.g. keep `mappedStrokes` + the map they were built for). The renderer now calls `scene()` only on frames it draws (≤60/s normally).
3. `Renderer.headsetZoom` and `Renderer.viewports(...)` are gone (nothing else used them).
