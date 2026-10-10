# DrawCompanion: design and critique

## The pitch

You draw on real paper, wearing a headset. When you get stuck you ask for help, by voice ("add a cat on the windowsill") or just "what should I add?". A few seconds later an outline appears on your paper. It matches your drawing's style, scale and colors, so you can trace it. When you've traced it, it disappears.

## The honest critique

The idea is good. Drawing assistants on screens already exist; putting the guidance *on the paper* is the part that's new and worth doing. Three things decide whether it works:

1. **Does the outline actually fit the drawing?** (generation quality)
2. **Does it stay glued to the paper while you draw?** (tracking and rendering)
3. **Does it understand what you meant, and get out of the way when you're done?** (interaction)

The original concept describes the happy path for each one. Here is where each one breaks and what to do about it.

---

### 1. Hardware: the headset is the riskiest assumption

- **Video passthrough headsets** (Quest 3, Vision Pro) show you the paper through cameras. That costs resolution and adds a little latency and warping, and it all lands on your hand-eye coordination. Fine pencil work through passthrough is noticeably harder than drawing with your own eyes. Headsets are also heavy for a 1–2 hour drawing session.
- **Camera access is gated.** To see your page, the app needs the headset's camera frames. Quest 3/3S expose them through Meta's Passthrough Camera API. On Vision Pro, main-camera access is limited to enterprise entitlements. Android XR allows it with a permission. So platform choice is not free.
- **Optical see-through glasses** let you see the real paper. Their overlays are dim in a bright room and have a small field of view, but a small field of view is fine for a sheet of paper.

**Recommendation:** keep the pipeline device-agnostic and ship the first version as a phone or tablet on a stand over the paper. That's the "magic window" mode this repo implements. Existing AR tracing apps already prove people will draw this way. The headset becomes one more display target once the hard parts (generation, tracking, completion) work. Don't make the whole product depend on it.

### 2. Generation: an LLM drawing coordinates is a good start, not the end

This prototype has Claude look at a perspective-corrected photo of the page, with a labeled coordinate grid drawn on it, and return vector strokes as JSON. It is fast and handles composition well: where to put things, what fits the scene, matching the scale. It is weak at complex organic shapes like a realistic hand, a face in 3/4 view, or fur. The lines come out schematic.

**The better pipeline (v2)** keeps the same output schema, so the client doesn't change:

1. **Claude as art director.** Interpret the request and the page. Choose the region. Describe the style (medium, line weight, how loose or tight). Pick the palette from what's already on the page. Write the generation prompt.
2. **An image model draws.** Inpaint just that region of the rectified photo, conditioned on the rest of the page, so the result inherits the user's actual style.
3. **Lines are extracted, not imagined.** Diff the inpainted image against the original page. Run line extraction (edges or a line-art model) on the new content, then vectorize and simplify into the same `construction / contour / detail` strokes.

Claude stays responsible for understanding intent and composition. The image model is responsible for pixel-level fidelity. Each does what it's good at.

### 3. Latency: "a few seconds" feels long when you're mid-stroke

Design for *perceived* latency:

- **Acknowledge instantly.** The target area starts pulsing the moment you ask. This is implemented.
- **Reveal progressively.** Show the placement box, then construction shapes, then contours. Streaming the structured output lets the first strokes appear before the last ones are generated.
- **Make adjustments without a model call.** Pinch to move or scale the outline, and turn "a bit bigger" or "more to the left" into a local transform. Only call the model again when the *idea* changes.
- The prototype runs at low effort because a good-enough answer in time beats a perfect one late. Tune this per mode.

### 4. Turning what the user wants into an outline

This is the core of the product. The original concept treats it as one step: ask, then get an outline. It should be a short conversation with three levers:

**a. Where.** "Put a bird here" only works if *here* is captured. In a headset the natural input is pointing with your pencil tip or finger while you speak ("put that there"). The prototype uses drag-a-box as the stand-in. With no region, the model chooses the placement and says why.

**b. What, when the request is vague.** "I'm stuck" is the most common request and the hardest one. Answer it with **3 ideas** (implemented as a mode) that you flip through on the paper itself. You choose by looking at them in place, which beats any text description.

**c. How much help.** One ghost outline doesn't suit everyone:

| Mode | What you get | Who it's for |
|---|---|---|
| **Guides only** (implemented) | Construction shapes, center lines, perspective guides | People learning, or who want the final line to be theirs |
| **Outline** (implemented) | Guides plus contours plus a little detail | "Just help me get this right" |
| **3 ideas** (implemented) | Three light alternatives | "I'm stuck, inspire me" |
| **Critique** (future) | Text plus marks: "the horizon tilts, here's the vanishing line" | Fixing what's already there |

**d. Refinement.** After an outline is up, "make it face left" or "smaller, and sitting rather than standing" should edit *this* suggestion, not start over. Keep the request history server-side and send the current strokes back as context.

**e. Style matching.** Today's prompt tells the model to match line weight, looseness and level of detail. Two cheap improvements: white-balance the photo using the paper itself as the reference white, so palette suggestions are true colors and not the lamp's tint; and remember a style profile per drawing, so suggestion five matches suggestion one.

### 5. Color: an outline can't carry it

The concept promises color-aware suggestions, but a line has no fill. Options:

- **Palette swatches** with "where it goes" labels (implemented, in the side panel). In a headset, anchor them next to the region.
- **Peek:** hold a button to see a translucent colored preview of the suggestion, and let go to return to the lines. This conveys color without cluttering the tracing view.
- Use colors already on the page first, plus at most one new one, so suggestions don't fight the existing palette. This is in the prompt.

### 6. "Disappears when you finish" needs a definition

A binary "done, then vanish" is fragile. Hands, shadows and lighting changes all look like new marks, and people rarely trace 100% of a line. What's implemented (`public/completion.js`):

- **Per-stroke fading.** Each stroke dims as you trace it, so the untraced parts stand out. The whole outline fades out when about 80% of each contour or detail stroke is traced.
- **Construction lines don't block completion.** People rarely ink them, so they go away with the rest.
- **Hands aren't ink.** A mark only counts if it is *thin* (a line, not a blob) and stays for several frames. A big change across the page pauses tracking instead of counting as drawing. If that lasts, the app asks whether the paper moved.
- **Lighting drift** is normalized against the page's overall brightness.
- **Manual "Hide outline"** is always available.

Still to do: if you clearly drew *your own version* in the region and not on the lines, fade the outline anyway, and maybe ask "keep the guide?". Ignoring the suggestion is a valid outcome, not a failure.

### 7. Tracking and rendering

- **Paper moves.** People rotate the page constantly while drawing. Tapping corners works for a prototype with the camera on a stand. Production needs automatic page detection (fit a quadrilateral to the paper edge) plus frame-to-frame tracking. The drawing itself gives the tracker more texture as it grows. Fiducial markers on a drawing board are the most robust fallback.
- **Draw under the hand.** If the outline renders on top of your hand and pencil, it hides the pen tip, which is exactly where you're looking. Headsets with hand tracking can mask overlays behind the hand. On a phone, a hand-segmentation model does the same job.
- **Size lines in millimeters on the paper, not in screen pixels**, so line weight is consistent at any distance. The halo already keeps lines readable on both white paper and dark ink.

### 8. Privacy, cost, and ownership

- **Only the page leaves the device.** The client crops and rectifies to the paper before uploading, so the model never sees the room. This is implemented. Keep it as a hard rule.
- **Cost** scales with requests, not drawing time, because completion tracking is fully on-device. A 768-px page image plus a short prompt is a small request.
- **Ownership and learning.** If the default is always "trace this", users can end up dependent on the tool. Offer *Guides only* prominently, and consider a mode that shows the outline briefly and then hides it, so you draw from memory.

## Architecture (as built)

```
 camera frame ──► tap 4 corners ──► homography H (paper ⇄ camera)
      │
      ├─ ask ─► rectify page (768px) + labeled grid ─► POST /api/suggest
      │                                                    │
      │                     server: Claude (vision, structured output)
      │                     → { understood, style_notes,
      │                         suggestions: [{ strokes[role, points, weight],
      │                                         palette, steps, placement }] }
      │                     → sanitize (clamp to page, drop bad strokes)
      │                                                    │
      └─ every frame: project strokes through H onto video ◄┘
         every 400ms: rectify (200px gray) → CompletionTracker → fade strokes
```

Coordinates are **paper units**: the page is 1000 wide and the height follows the paper's aspect ratio. Every component speaks this one coordinate system, so swapping the generator (LLM today, inpainting pipeline tomorrow) or the display (phone today, headset tomorrow) doesn't touch the others.

## Roadmap

1. **Now (this repo):** phone/tablet prototype, Claude-generated strokes, three help modes, completion tracking.
2. **Better outlines:** the art-director + inpainting + line-extraction pipeline; streaming progressive reveal; pinch to move or scale.
3. **Robust tracking:** automatic page detection, rotation tracking, hand occlusion.
4. **Headset:** a native app on a headset with camera access (Quest 3 via the Passthrough Camera API is the most accessible today), pencil-tip pointing, voice-first flow.
5. **Conversation:** refine-in-place, critique mode, per-drawing style memory.

## What to measure

- **Time to first line:** from finishing the request to the first stroke on paper. Target under 3 s perceived.
- **Acceptance rate:** suggestions the user traces at least half of.
- **Alignment error:** millimeters between projected and intended stroke positions.
- **False fades:** outlines that disappeared before the user was done, found from manual re-shows.
- **Re-ask rate:** an immediate second request on the same region usually means the first one missed.
