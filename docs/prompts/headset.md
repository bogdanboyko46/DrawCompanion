You are the HEADSET session for DrawCompanion (repo bogdanboyko46/DrawCompanion). Work on branch ar/headset: check it out first (`git fetch origin ar/headset && git checkout ar/headset`) and push only there.

Read these first: docs/WORKSTREAMS.md (rules and who owns which file; follow it strictly), ios/README.md, docs/DESIGN.md, then the files you own: ios/DrawCompanionAR/AR/Renderer.swift, AR/Shaders.metal, AR/CameraView.swift, UI/HeadsetOverlay.swift.

What the app is: an iPhone app (ARKit + Metal, landscape) for drawing on real paper while the phone sits in a head-mounted viewer. You talk; Claude places an outline on your paper; you trace it. In "Headset view" the camera image is drawn twice side by side, one per eye, with the outline on top (Renderer.viewports, Renderer.headsetZoom = 1.6). The outline is already drawn in the user's ink color and paper-unit thickness and fades under the hand (person segmentation mask in lineFragment). Tracking and drift correction are owned by the lead; don't change them.

Your goal by 5 AM EST: make the headset view genuinely comfortable and impressive to use in a cheap phone viewer (Cardboard-style lenses).
1. Lens distortion pre-correction: render each eye through a barrel-distortion mesh/shader (standard k1, k2 radial model, defaults suited to Cardboard-style viewers) so straight paper edges look straight through the lenses. Parameters in one struct with sensible defaults. Put the math in Core (e.g. Core/HeadsetOptics.swift) with unit tests.
2. Eye layout: per-eye center offset / IPD and zoom (field of view) adjustable. Expose them as values the UX session can later put in Settings (UserDefaults keys you define; list them in docs/status/headset.md). Defaults that look right on an iPhone 17 Pro in a typical viewer.
3. Line quality: 4x MSAA or equivalent so outline lines are smooth, not jagged; check dashes still look right; keep transparency.
4. Smoothness: render at the display's max frame rate (ProMotion 120 Hz if available), avoid per-frame allocations in the render loop (reuse Metal buffers), keep CPU work per frame small.
5. Optional if time allows: a subtle fade-in of each new stroke as it arrives (strokes stream in one by one).

Constraints: follow docs/WORKSTREAMS.md strictly. Only edit files you own. Never try to run the app (the lead tests on the iPhone). You have no Xcode: after every push, check the "Checks" workflow run for your branch with the GitHub tools (it runs `swift test --package-path ios` and builds the iPhone app on a Mac) and fix failures before moving on. Keep docs/status/headset.md on your branch up to date, including "Requests for the lead" for changes to files you don't own, and mark items "READY TO MERGE" only when CI is green. Work until 5 AM EST.
