# AI session status

**Branch: `claude/zealous-archimedes-jo4rf9`** (based on `ar/ai`)

Updated: 2026-10-11, early night (EST evening).

## Important: no API key in this cloud environment

`ANTHROPIC_API_KEY` is not set here, so **no live model calls have been made**: the eval is built, checked end to end against a local fake API (`eval/mock-api.mjs`), and ready to run with a key. All numbers below that need the real models are "to measure". To run it on the Mac: see `eval/README.md` (about $0.35 per drawing variant, < $0.01 for the filter set; it stops itself at $4.50 total).

## Done

| Item | Status | CI |
|---|---|---|
| Retries on transient API errors (429, 5xx, 529 overloaded, dropped connection, timeouts): 2 retries after 0.4 s and 1.2 s; never after strokes are already on the paper; a cancelled turn stops at once | READY TO MERGE | green, run 24 |
| Clear errors: wrong key (401), not allowed (403), no credit (402), rate limited (429), overloaded (5xx/529), Claude declined (refusal) | READY TO MERGE | green |
| Never a silent "nothing happened": a drawing with no visible stroke (the "M 0 0" answer) is retried, then reported as "Claude didn't draw anything for that. Try saying it differently." Dots and zero-length strokes are dropped | READY TO MERGE | green |
| Filter: revise-vs-new fix. Revise only when the words are about the shown outline itself; a request for a different thing (outline from "add an arm", then "can you add teeth to the smile?") is new. Same wording in `server/suggest.js` | READY TO MERGE (prompt change; to measure with `node eval/run.mjs filter`) | green |
| Placement wording: an extra copy of a part (third leg, another eye) goes beside the existing ones, never on top; things on/in a named part (teeth in the smile, a hat) go there; compare part boxes before choosing the place | READY TO MERGE (to measure with `node eval/run.mjs draw`) | green |
| Speed: the drawing call starts **in parallel with the Haiku filter** when the words sound like a request (`Speculation.guess`, `TurnBackend.swift`). Strokes are held until the filter agrees; if it says ignore/hide (or the other of new/revise) the call is cancelled. Saves the filter's whole round trip before the first line. Chatter without request words never starts a call | READY TO MERGE | green |
| Eval (`eval/`): 19 drawing cases on the 3 real photos with hand-labeled part boxes, 30 filter phrases, automatic geometric scoring (target box, overlap with parts, overlap with the actual pencil lines, touching, size, revision scale/shift), latency (first text, first stroke, total, end to end sequential vs parallel), cost, overlays on the photos | done; needs a key to produce numbers | green (web tests) |

## What to look for on the phone

- First line should appear about one filter round trip (~0.5–1 s) sooner for requests like "add …", "draw …", "give him …", "make it bigger". Log: `[DC] filter: new (…) for […], speculated new`.
- "can you add teeth to the smile?" while another outline is shown should now be `filter: new`, not revise.
- Network hiccup / overloaded: `[DC] draw retry 1 in 0.4s after: …` and the turn still completes. A wrong key shows "The API key was rejected. Check it in Settings." right away (no retries).
- An empty answer now shows a message instead of nothing.

## Cost of speculation (estimate until measured)

A speculative call cancelled after the filter is billed for its input (2 photos + prompt, about 3k tokens = ~$0.006 on Sonnet 5.5) plus the little output written before the cancel. Only phrases containing request words ("add", "draw", "make", "want", "bigger", …) start one; in the 30-phrase filter set, 1 of 9 non-requests would ("I want to make dinner later"). `node eval/run.mjs filter --spec-cost` measures it. To turn it off: `ClaudeBackend(client:…, speculate: false)`.

## Next (needs a key)

1. `node eval/run.mjs filter` (old vs new prompt: `--prompts` with `git show a6ee6ca:ios/DrawCompanionAR/Core/Prompts.swift`).
2. `node eval/run.mjs draw` baseline, then `--model opus`, `--effort medium`, `--thinking between_tools`, `--closeup none` / `900-50-0.15` / `1200-50-0.4`, `--cache`; keep whatever wins.
3. Prompt caching: the drawing system prompt is ~900 tokens (above Sonnet 5.5's 512-token minimum) but the photos change every turn, so caching only saves the system prompt; with turns minutes apart the 5-minute cache mostly misses and writes cost 1.25x. Not enabled until `--cache` shows a gain.

## Requests for the lead

- None required to merge: `AppModel.makeBackend()` builds `ClaudeBackend(client:)` and gets speculation by default.
- Worth a look (`AR/PageImaging.swift`, yours): in `eval/photos`, `page-3-closeup.jpg`'s grid labels disagree with `page-3.jpg` by ~20 units (the head's left edge reads x≈352 in the close-up, x≈372 in the full page; width 150 vs 158). They may be from different frames. If you can, save `last-page.jpg` and `last-closeup.jpg` from the same turn and check a feature's coordinates in both; if they disagree, the close-up crop or its labels are off, which would directly hurt placement.
