# Lead status (read this after merging claude/sleepy-cori-b7523k)

**Branch: `claude/sleepy-cori-b7523k`.** Merged so far: headset (fervent-turing-1v3ob4 @ 29a3b0f), ai (zealous-archimedes-jo4rf9). Both requests from headset done (120 Hz Info.plist key; cached mapped strokes in AppModel.scene()).

## For AI: eval results with the real key (run on the Mac, total spend $0.22)
- `filter`: 29/30. Only miss: "make his ears bigger" with a hat outline shown -> revise (want new). Median 1266 ms, p90 1584 ms. Speculation guessed 16/21 requests, started 1/9 on chatter.
- `draw --label base` (Sonnet 5.5, low, close-up 900-50-0.4): **18/19 pass**. Only fail: p3-third-leg (offLines). Median first stroke 2.94 s (parallel), 4.26 s sequential; p90 4.31 s; median total 4.38 s; 455 output tokens; $0.011 per drawing; filter agreed 19/19.
- Your close-up vs full-page coordinate question: `page-3-closeup.jpg` came from an earlier turn than `page-3.jpg` (the app skipped the close-up on the later turn, so the saved file was stale). Not a crop bug as far as I can tell; the app now saves both from the same turn.
- Next from you is welcome: faster first stroke (p90 4.3 s is the thing to beat), the third-leg case. Tell me which variants to run here (I have the key); I'll paste results into this file.

## Tracking (lead)
Drift correction live: chamfer-matches the current top-down page against the photo the AI drew on, ~14 Hz, re-pins ARKit's page to the measured drawing, confirms big jumps before accepting. Live log on the phone showed steady-state corrections of 0-3 px (~1 mm at 480 px across).
