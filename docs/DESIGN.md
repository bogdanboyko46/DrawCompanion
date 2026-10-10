# DrawCompanion: design

## The product

You draw on real paper wearing a lightweight headset: your phone in a head-mounted viewer, using the phone's high-resolution camera. The microphone is always on, and you talk naturally: "I'm stuck, maybe a cat on the windowsill?" A few seconds later an outline appears on the paper, placed by the AI where it fits your drawing, and you trace it. "Bigger, and facing left" changes it. "Clear it" removes it. The AI never answers back in words or sound; it only acts on the outline. When you stop drawing on the outline for 3 seconds, it clears.

## Decisions

| Question | Decision |
|---|---|
| Display | **Headset**: a phone in a lightweight viewer (video see-through using the phone's camera). The handheld phone view stays for setup and debugging. |
| Outline generation | **Claude draws the strokes directly** from a photo of the page. No image-generation pipeline. |
| Which AI | **Two stages.** Claude Haiku 5.5 (fast, cheap) hears every phrase and decides what it means. Claude Opus 5.5 is called only when there's something to draw or change. |
| Where it goes | **Entirely the AI's call.** No box, no pointing: it reads the drawing and the request ("on the windowsill") and places the outline. |
| Talking to it | **Always listening, never replying.** Every phrase goes to the AI, which decides: draw something new, change the current outline, clear it, or ignore the speech (thinking aloud, talking to someone else). |
| Color | Not a focus. |
| When it disappears | **3 seconds after you stop drawing on the outline**, or when you ask it to clear. |

## How it works

```
 phone camera ──► find the 6 printed markers every frame ──► H (paper ⇄ camera)
      │
      ├─ microphone (always on) ─► each finished phrase
      │      → top-down page image (768px) + labeled grid
      │        + what was said + the outline currently shown ─► POST /api/turn
      │                                                            │
      │        server: 1. Haiku (text only) decides                │
      │                   new | revise | hide | ignore             │
      │                2. new/revise only: Opus + photo → strokes  │
      │                                                            │
      ├─ every frame: project strokes through H into both eyes ◄───┘
      │
      └─ every 300 ms: top-down 200px gray page → CompletionTracker
                       → traced strokes dim; 3 s without drawing on it → fade out
```

Everything is measured in **paper units**: the template's drawing frame is 1000 wide, and its height follows the paper (A4 or Letter). The generator, the tracker, and both views share this coordinate system.

### Finding the page (why there's a printed template)

In a headset the camera moves with your head, so tapping the paper's corners once (the first prototype's approach) stops working as soon as you look anywhere else. The page has to be found again every frame. The template has six markers: one inside each corner of the drawing frame and one at the middle of each long edge. Any single marker is enough to locate the whole page; more markers make it steadier. This gives three things:

- The outline stays on the paper while your head moves, and while you move or rotate the paper.
- Print scaling doesn't matter, since the coordinates come from the markers, not the sheet edges.
- The page is still found when your hand covers some markers or you lean in close and a few leave the view.

Detection runs on a 960-pixel-wide copy of each frame. The pose is fit to every visible marker corner (least squares, normalized) and ignores sub-pixel jitter, so a still page gives a still outline.

### The headset view

- The phone shows the camera image twice, side by side, one per eye, with the outline drawn into both. The camera is a single lens, so both eyes see the same image: the paper looks flat, without stereo depth. That's fine for a flat sheet.
- **No buttons, no pointing.** Entering the headset view starts the microphone, and from then on everything is speech.
- **No AI replies.** The only thing on screen besides your page and the outline is a small status dot low in each eye: green (listening), pulsing blue (working on what you said), orange (can't see the page), grey (microphone off). Text appears only for setup problems such as a blocked microphone or an unreachable server.

### Talking to it

- **Every phrase is a turn.** When the speech recognizer finishes a phrase, the app sends it with a fresh photo of the page and the outline currently shown (plus the requests that produced it). The server handles it in two stages:
  1. **Filter (Claude Haiku 5.5, text only).** Reads what was said and whether an outline is showing, and picks the action below. It doesn't see the photo, which keeps it quick and costs a fraction of a cent. Chatter, "clear it", and anything ignored stop here.
  2. **Draw (Claude Opus 5.5, with the photo).** Runs only for new and revise, and returns the strokes.

  The actions:

| Action | When | Example |
|---|---|---|
| new | A request for something to draw | "I'm stuck… maybe a cat on the windowsill" |
| revise | A change to the current outline | "bigger", "make it face left", "no, a pine tree" |
| hide | Wants it gone | "clear it", "I've got it" |
| ignore | Anything else | thinking aloud, talking to someone, filler |

  When unsure between ignoring and drawing something nobody asked for, the prompt tells it to ignore.
- **Keep talking and it catches up.** If you say something while the previous phrase is still being processed, that request is cancelled (the server stops the model call, so you don't pay for it) and everything said since the last action is sent together. "Can you add…" followed by "…a flower next to the house" becomes one request.
- **Placement is the AI's job.** It reads what's on the page, its perspective and scale, where the composition has room, and any place named in the request. The model reads positions off a labeled grid drawn on the image, which makes its coordinates much more accurate.
- If the page isn't in view when you speak, the phrase waits and is sent as soon as the markers are seen again.

### When the outline clears

Implemented in `public/completion.js`, and unit-tested:

- The outline **waits until you start tracing**. Asking and then thinking about it doesn't make it vanish.
- Each time new ink lands on the outline, the **3-second countdown restarts**. When it runs out, the outline fades.
- **A hand on the outline counts as still drawing.** Your hand covers the line you just drew, so new ink often shows up only after the hand moves. A hand over the outline holds the timer instead of letting it run out under you.
- **Hands aren't ink.** Ink is a *thin* new dark mark that persists for a few frames; a hand is a large blob of change.
- **Head movement isn't ink.** Frames where the page moved fast (blurred, misaligned) are skipped, and a pixel only counts as ink if it's darker than everything near it in the "before" image, so existing lines that shift a pixel or two don't register.
- Traced strokes dim so the remaining ones stand out. Asking to clear it ("clear it", "got it") removes it right away.

## Risks that remain

1. **Placement without a box.** The AI must infer where you mean from the drawing and your words. When it guesses wrong, "move it to the left of the house" fixes it, but each fix is another round trip. Watch how often the first placement needs moving.
2. **An always-on microphone.** Every phrase costs a Haiku call (cheap), and drawing requests pay for two calls in a row, so they take a little longer than a single call would. The filter only reads words: a phrase that only makes sense with the picture ("that one's too dark") is judged without it. Also: browser speech recognition on Chrome sends audio to the browser vendor's speech service; users should know the microphone is live the whole time.
3. **Ignoring the right things.** "That flower looks bad" could be a request or just a comment. Measure false draws (outlines nobody asked for) and missed requests.
4. **Hand-eye coordination through a camera.** You draw while watching a camera feed on a screen centimeters from your eyes. The `ZOOM` constant in `public/app.js` sets how much of the camera image each eye sees and is the main thing to tune on the real viewer. Lens distortion correction for the specific viewer is not done yet.
5. **Leaning in very close** can push every marker out of view. The outline then hides until a marker is visible again.
6. **Resting your hand on the outline without drawing** keeps it up. That fits the rule (you might still be drawing); lifting your hand starts the countdown.
7. **Phone heat and battery.** Camera, per-frame marker detection, speech recognition and a full-brightness screen are a heavy load. Long sessions need testing.

## Roadmap

1. **Now (this repo):** headset and phone views, printed-template tracking, always-on voice with a Haiku filter and Opus drawing, AI-decided placement, 3-second clearing.
2. **Latency:** stream the drawing so construction lines appear first; measure whether the drawing stage can move to a faster model without hurting placement.
3. **Comfort:** per-viewer lens correction and zoom calibration.
4. **Polish:** a per-drawing style memory, so later suggestions match earlier ones.

## What to measure

- **Time to first line:** from the end of a phrase to the outline appearing. Target under 3 s.
- **Placement accepted:** outlines traced without a "move it" correction.
- **False draws and missed requests:** outlines nobody asked for; requests that were ignored.
- **Early clears:** outlines that faded while the user was still drawing.
- **Filter accuracy:** phrases the filter ignored that were requests, and chatter it passed on to the drawing model.
- **Drawing calls per session** versus phrases heard.
