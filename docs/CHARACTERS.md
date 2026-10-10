# Drawing to living 3D character: design

The goal: a figure drawn on paper becomes a detailed 3D character that stands on the real desk, moves like it's alive, and is unmistakably *the one you drew*.

## What decides whether it's impressive

1. **Fidelity.** If it doesn't look like your drawing, nothing else matters. Generic "a cat" output is a failure even when it's beautiful.
2. **Detail.** Painted textures, real volume, no melted limbs. A puffy inflated sketch isn't enough.
3. **Life.** It has to move, notice you, and react. A static model on a table is a demo, not a character.
4. **The reveal.** Two minutes of a spinner kills the magic. The waiting time itself has to be part of the show.

Each stage of the pipeline exists to protect one of these.

## Pipeline

```
 phone                                    server                                   Meshy / Claude
 ─────                                    ──────                                   ──────────────
 detect paper (Vision, 5 Hz)
 high-res still → rectify to the
 paper's measured aspect, white-balance
 against the paper, cut out the figure
           │ JPEG ─────────────────────▶  read     Claude: character sheet ───────▶ name, body plan, riggable?,
           │                                       (name, colors, details,           design details, palette,
 portal: cutout peels off the page                 concept prompt, personality,      personality, clip picks
           │                                       clip picks from the library)
           │                              concept  image-to-image, multi-view ────▶ front/side/back, T-pose,
 concept fades in on the card ◀── png ──           T-pose, white background            same design
           │                              review   Claude compares to drawing ─────▶ faithful? else one repaint
           │                              sculpt   multi-image-to-3D, PBR, ~50k tris
 stage card: sculpt → rig → animate       rig      auto-rig (humanoids) + walk/run
           │                              animate  personality-matched clips
           │                              package  Blender: all clips on one timeline → one USDZ + clip manifest
 burst → character appears ◀── usdz ────
 brain: idle, look, wander, greet, react
```

### Why Claude reads the drawing first

Image-to-3D models are literal: feed them a pencil sketch and they sculpt pencil lines. The fix is a concept render, a clean, painted, front-facing, T-posed version of the same design, but a generic "make this 3D" prompt loses what makes the drawing *yours*. So Claude writes the prompt from what it sees: every distinctive detail (the scarf, the three eyes, the lopsided ears), the palette (taken from the drawing, or invented and flagged if the drawing is uncolored), and instructions to keep the proportions and charm rather than "fix" them. The same sheet decides:

- **Riggable or not.** The auto-rigger only handles humanoids. Asking for a T-pose on a quadruped wastes the concept, so the sheet decides up front.
- **Animations.** Claude picks clips from Meshy's library to match the personality: a shy character gets a timid wave, an energetic one a big jump.
- **Personality numbers.** `energy` and `friendliness` drive the brain on the phone: walk speed, how often it wanders, and whether it greets you when you come close.

### Why there's a review step

Image models drift: they drop accessories, change colors, add a fourth finger, crop the feet. A drifted concept costs about 30 credits of 3D that's wrong. Claude compares the concept to the drawing and, if a difference matters ("lost the scarf"), writes a corrected prompt. The pipeline repaints once. It's a cheap check in front of the expensive step.

### Why multi-view

A single front view leaves the back to the 3D model's imagination. Painting front, side and back views from the same prompt, then using multi-image-to-3D, gives consistent volume and a back that matches.

### Why one USDZ with a timeline

RealityKit loads USD only, and Meshy returns the rig and each animation as separate GLBs. Retargeting clips across separately loaded USDZs is fragile. Instead `server/character/pack_usdz.py` (Blender's `bpy`) imports everything, lays the clips end to end on one NLA track, and exports one Y-up, +Z-forward USDZ plus `clips.json` with each clip's time range. On the phone, `AnimationView(trimStart:trimEnd:)` slices the timeline back into clips. This path is tested in mock mode: the sample character goes through the same packer.

### Why it's resumable

A character takes a few minutes and several paid tasks. Every remote task id is written to `job.json` as soon as it exists. Restart the server and it resumes polling. Retry a failed job and finished stages are skipped. A task that failed for good is dropped so the retry starts it fresh.

## Life on the phone

`CharacterActor` runs a small state machine every frame:

| State | Behavior |
|---|---|
| appearing | Pops in at the paper with overshoot, greets, says its line |
| idle | Faces you when you're within ~1.5 m. Every few seconds (faster when energetic) decides to wander, look around, or do a happy clip |
| walking | Turns first, then walks (no moonwalking) at a body-length-based speed. Targets are checked against real plane geometry so it doesn't walk off the desk |
| performing | Plays a one-shot clip, then returns to idle |

Rigged characters crossfade between trimmed clips. Static characters get procedural motion (breathing, squash-and-stretch hops, a spin jump), so the auto-rigger declining a character never means a lifeless result.

Grounding: plane-anchored entities get ARView grounding shadows plus `GroundingShadowComponent`. People occlusion lets your hand pass in front. On LiDAR devices, the scene mesh occludes it behind real objects. Environment texturing lights it with the room.

## Failure modes and what happens

| Situation | Result |
|---|---|
| No character on the page | Fails in seconds with Claude's friendly reason. Nothing is paid to Meshy |
| Concept drifted | One corrected repaint |
| Not humanoid | Static model with procedural motion |
| Rigging fails anyway | Same: ships static, the job doesn't fail |
| One animation fails | The others still ship. The brain fills gaps (idle ← any loop, walk ← run, greet ← happy) |
| No paper found | Uses the center of the frame. The character appears where you're pointing |
| Server restarts mid-job | Resumes polling the saved tasks |

## Next

- **Voice:** say "make it a dragon" while pointing. The hint field already flows into the character sheet.
- **Talk back:** a short Claude call per tap for in-character lines instead of canned ones.
- **Paper drawings that change:** add a hat to the drawing and the character puts it on (retexture).
- **Shared AR:** two phones see the same character (ARKit collaborative sessions).
- **Streaming the reveal:** show Meshy's preview mesh as a hologram during the sculpt stage.
