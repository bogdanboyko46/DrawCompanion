# DrawCompanion: design

## The product

You draw on real paper wearing a lightweight headset: your phone in a head-mounted viewer, using the phone's high-resolution camera. When you're stuck, you look at the spot where you want help and box it with two taps, then say what you want ("a cat sitting here"). A few seconds later an outline appears in the box, matched to your drawing, and you trace it. If it's not right, tap and say what to change ("smaller, facing left"). When you stop drawing on the outline for 3 seconds, it clears.

## Decisions

These were settled after the first round of critique:

| Question | Decision |
|---|---|
| Display | **Headset**: a phone in a lightweight viewer (video see-through using the phone's camera). The handheld phone view stays for setup and debugging. |
| Outline generation | **Claude draws the strokes directly** from a photo of the page. No image-generation pipeline. |
| Telling it where | **Box the spot.** The box is the placement context: the suggestion fills it and fits what's around it. |
| Not what you wanted | **Feedback loop.** Say what to change; the suggestion is revised in place, keeping everything you didn't object to. |
| Color | Not a focus. Swatches are shown in the phone view; nothing more. |
| When it disappears | **3 seconds after you stop drawing on the outline.** |

## How it works

```
 phone camera ──► find the 6 printed markers every frame ──► H (paper ⇄ camera)
      │
      ├─ box: two taps with the head-aimed dot (or a drag on the phone)
      │       → corners converted to paper coordinates, so the box stays put
      │
      ├─ ask (voice) ─► top-down page image (768px) + labeled grid + box ─► POST /api/suggest
      │                                                                        │
      │        server: Claude (vision, structured output) → strokes, steps     │
      │        feedback → same call + previous suggestion + feedback list      │
      │                                                                        │
      ├─ every frame: project strokes through H into both eyes ◄───────────────┘
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
- **Look and tap.** A dot sits in the center of each eye, and it marks the center of the camera image. Viewers have a button that taps the screen; every tap acts on whatever the dot is on:

| You're… | Tap does |
|---|---|
| Ready | Start a box at the dot |
| Boxing | Finish the box at the dot, then start listening |
| Listening | Stop listening |
| Seeing an outline | Listen for a change ("bigger", "facing left", "next idea", "hide") |

- **Voice picks the mode.** "Give me some ideas for…" asks for 3 options, and "just the guides for…" asks for construction lines only. Anything else uses the default outline mode.
- Status text is drawn inside each eye, because the phone's normal interface isn't visible in the viewer.

### Placement and feedback

- The prompt treats the box as the place for the suggestion: fill it, connect to lines that touch it, and match the perspective and scale of what's next to it. The model reads positions off a labeled grid drawn on the image, which makes its coordinates much more accurate.
- **Feedback** sends the previous suggestion's strokes, the full list of feedback so far, and a fresh photo (you may have started drawing). The model changes only what you asked for. If the revision fails, the previous outline stays.

### When the outline clears

Implemented in `public/completion.js`, and unit-tested:

- The outline **waits until you start tracing**. Asking and then thinking about it doesn't make it vanish.
- Each time new ink lands on the outline, the **3-second countdown restarts**. When it runs out, the outline fades.
- **A hand on the outline counts as still drawing.** Your hand covers the line you just drew, so new ink often shows up only after the hand moves. A hand over the outline holds the timer instead of letting it run out under you.
- **Hands aren't ink.** Ink is a *thin* new dark mark that persists for a few frames; a hand is a large blob of change.
- **Head movement isn't ink.** Frames where the page moved fast (blurred, misaligned) are skipped, and a pixel only counts as ink if it's darker than everything near it in the "before" image, so existing lines that shift a pixel or two don't register.
- Traced strokes dim so the remaining ones stand out. "Hide" (voice or button) clears it immediately.

## Risks that remain

1. **Hand-eye coordination through a camera.** You draw while watching a camera feed on a screen centimeters from your eyes. Latency, focus, and the slight scale mismatch between what you see and where your hand is all affect precision. The `ZOOM` constant in `public/app.js` sets how much of the camera image each eye sees and is the main thing to tune on the real viewer. Lens distortion correction for the specific viewer is not done yet.
2. **Leaning in very close** can push every marker out of view. The outline then hides until a marker is visible again. More markers along the edges would help if this shows up in testing.
3. **Resting your hand on the outline without drawing** keeps the outline up. That fits the rule (you might still be drawing); lifting your hand starts the countdown.
4. **Claude-drawn strokes** are good at placement and simple-to-moderate forms. Very intricate subjects may come out simplified; the feedback loop is the fix.
5. **Phone heat and battery.** Camera, per-frame marker detection, and a full-brightness screen are a heavy load. Long sessions need testing.

## Roadmap

1. **Now (this repo):** headset and phone views, printed template tracking, box + voice requests, feedback revisions, 3-second clearing.
2. **Comfort:** per-viewer lens correction and zoom calibration, an on-screen "lean back" warning when markers drop out.
3. **Speed:** stream the structured output so construction lines appear first.
4. **Polish:** a per-drawing style memory, so later suggestions match earlier ones.

## What to measure

- **Time to first line:** from finishing speaking to the outline appearing. Target under 3 s.
- **Accepted on first try:** suggestions traced without any feedback round.
- **Feedback rounds per suggestion:** high numbers mean the first attempt is misreading the box or the request.
- **Early clears:** outlines that faded while the user was still drawing.
- **Tracking dropouts:** seconds per session with no markers in view.
