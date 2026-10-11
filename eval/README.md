# AI eval: placement, speed, filter accuracy

Repeatable checks of what the iPhone app sends to Claude, on real page photos from the phone (`photos/`). Prompts are read straight from `ios/DrawCompanionAR/Core/Prompts.swift`, so the eval tests what ships.

## Setup (once)

```bash
npm ci                                   # @anthropic-ai/sdk, from the repo root
python3 -m venv .venv && .venv/bin/pip install Pillow   # or any Python with Pillow
python3 eval/prep.py                     # close-ups like the app's (900 px, grid every 50, margin 0.4)
python3 eval/ink.py                      # where the existing pencil lines are, for scoring
export ANTHROPIC_API_KEY=...
```

## Run

```bash
node eval/run.mjs filter                 # 30 phrases: new / revise / hide / ignore (Haiku, < $0.01)
node eval/run.mjs filter --spec-cost     # + what a cancelled speculative drawing call costs
node eval/run.mjs draw                   # 19 drawing cases as the app does them (~$0.30 on Sonnet)
python3 eval/render.py <label>           # outlines drawn on the photos: eval/results/<label>.png
```

Variants of the drawing call (see the top of `run.mjs`):

```bash
node eval/run.mjs draw --model opus                     # Opus 5.5 instead of Sonnet 5.5 (~2x cost)
node eval/run.mjs draw --effort medium
node eval/run.mjs draw --thinking between_tools         # Sonnet 5.5 with no extended thinking
node eval/run.mjs draw --closeup none                   # full page only
python3 eval/prep.py 900 50 0.15 && node eval/run.mjs draw --closeup 900-50-0.15   # tighter close-up
python3 eval/prep.py 1200 50 0.4 && node eval/run.mjs draw --closeup 1200-50-0.4   # bigger close-up
node eval/run.mjs draw --cache                          # prompt caching on the system prompt
git show a6ee6ca:ios/DrawCompanionAR/Core/Prompts.swift > /tmp/old.swift && node eval/run.mjs draw --prompts /tmp/old.swift
node eval/run.mjs draw --repeat 2 --only p3-third-leg,p3-nose
```

No key? `node eval/mock-api.mjs &` then `ANTHROPIC_API_KEY=mock ANTHROPIC_BASE_URL=http://localhost:8899 node eval/run.mjs draw --label mock` checks the harness for free.

Spend is added up in `results/spend.json` (local, not committed); the runner stops past $4.50.

## How it scores

`cases.json` has, for each photo, hand-labeled boxes of the existing parts (head, ears, legs, eyes, smile, flag, hair), read off an enlarged, gridded crop. Each drawing case says where the new piece should be and what it must not cover:

| Check | Meaning |
|---|---|
| where | the center of the new outline (construction lines left out) is inside a target box |
| clear | at most 15% of the outline lies inside the parts it should avoid (boxes shrunk 12%) |
| offLines | at most 25% of the outline lies within 4 units of existing pencil lines (45% when it should touch a part); catches "a leg drawn on top of a leg" |
| touches | for "teeth in the smile", "a hat on him": comes within 12 units of that part |
| size | for small parts (nose, eye, teeth): not bigger than the case allows |
| revisions | "bigger" grows >= 1.25x in place; "smaller" shrinks; "move it left" moves left 10–200 units and stays level |

Latency per case: time to first text, first usable stroke and the whole drawing (from the request), the filter's time, and end to end from the end of the phrase:
- **sequential** = filter + first stroke (the app before speculation)
- **parallel** = max(filter, first stroke) (the app now, when its word-based guess is right)

The close-ups here are cut from the 768 px photos, so they're softer than the phone's (cut from a 1600 px page); positions are identical.

## Cases

- Placement problems seen on the phone: "add a third leg" (drawn on a leg), "add a nose" (on an eye).
- Adding to a named part: teeth in the smile, a hat, shoes, a second flag, a third eye.
- Empty space: sun in the corner, flower bottom left, house on the right, tree to the left, dog beside him, speech bubble.
- Relative placement: ball right of the legs, cloud above, grass under the feet.
- Revisions of a shown outline: bigger, smaller, move left.
- Filter: the "teeth to the smile while an arm is shown" confusion, other new-vs-revise pairs, hides, chatter.

## Prompt variants

`variants/` holds edited copies of `Prompts.swift` for `--prompts`:
- `parts-max5.swift`: at most 5 nearby parts before the strokes (the parts list is written before the first stroke, so it delays the first line).
- `no-parts.swift`: strokes only, no parts/place (the schema before the parts-first change; fastest, placement was worse in the lead's tests).

They're snapshots: regenerate them if `Prompts.swift` changes (the commands are in `docs/status/ai.md`).
