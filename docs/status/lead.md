# Lead status (read this after merging claude/sleepy-cori-b7523k)

**Branch: `claude/sleepy-cori-b7523k`.** Merged so far: headset (fervent-turing-1v3ob4 @ 29a3b0f), ai (zealous-archimedes-jo4rf9), ux (dreamy-ramanujan-f4loae @ c44c68a). Requests done: headset (120 Hz key, cached strokes in AppModel.scene()); ux (Sample AI toggle in AppModel, ASSETCATALOG_COMPILER_APPICON_NAME).

## For AI: eval results with the real key (run on the Mac, total spend $0.22)
- `filter`: 29/30. Only miss: "make his ears bigger" with a hat outline shown -> revise (want new). Median 1266 ms, p90 1584 ms. Speculation guessed 16/21 requests, started 1/9 on chatter.
- `draw --label base` (Sonnet 5.5, low, close-up 900-50-0.4): **18/19 pass**. Only fail: p3-third-leg (offLines). Median first stroke 2.94 s (parallel), 4.26 s sequential; p90 4.31 s; median total 4.38 s; 455 output tokens; $0.011 per drawing; filter agreed 19/19.
- Your close-up vs full-page coordinate question: `page-3-closeup.jpg` came from an earlier turn than `page-3.jpg` (the app skipped the close-up on the later turn, so the saved file was stale). Not a crop bug as far as I can tell; the app now saves both from the same turn.
- Next from you is welcome: faster first stroke (p90 4.3 s is the thing to beat), the third-leg case. Tell me which variants to run here (I have the key); I'll paste results into this file.

## Tracking (lead)
Drift correction live: chamfer-matches the current top-down page against the photo the AI drew on, ~14 Hz, re-pins ARKit's page to the measured drawing, confirms big jumps before accepting. Live log on the phone showed steady-state corrections of 0-3 px (~1 mm at 480 px across).

## Change of direction (user decision, all sessions please read)
The app now uses the **normal full-screen AR view only**. The side-by-side headset view is switched off (`AppModel.headsetAvailable = false`; the Headset view button, the welcome tip and the Settings headset section are hidden behind it). The headset code stays but isn't the focus now.
- **Headset session:** please shift to the normal AR view: line quality, draw-on animation, smoothness and 120 Hz in the single full-screen view, plus anything that makes the outline look like it's printed on the paper (e.g. how it sits under the hand, how traced strokes fade).
- **UX session:** keep `if AppModel.headsetAvailable` around headset UI when you touch those files.

## Phone test findings (after merging everyone), for all sessions
- **AI:** on a stick-figure drawing (thin pencil, small), "add …" produced a big cartoon figure with a huge oval head, much larger and in a different style than the user's drawing. Placement relative to the user's figure was fine; scale and style were not. Please make size and style matching a scored case in the eval (new figure should be about the size of the existing one, same simplicity) and tune the prompt.
- **Lead fixed (03e42c1):** ink detection was global, so a shadow over half the page broke the aligner (stretching), the ink color (brown) and the line width (maxed out), and the close-up region. Now local/shadow-proof (`DrawingAligner.lineMask`, shared by InkStyle and PageRegion). If you touch InkStyle/PageRegion, keep using lineMask.
- **Headset/renderer:** line width = style.width (paper units) × projected scale; with the ink-style fix, widths should match the pencil again. If lines still look too heavy on the phone I'll report back.
