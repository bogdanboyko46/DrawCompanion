# Placement experiments (from the lead session)

Earlier tests on a real page photo (eval/photos/page-2.jpg) that led to the current design:
- `compare1.png`: full-page photo only. The "third leg" landed on an existing leg; the nose outside the face.
- `compare4.png`: full page + enlarged close-up + "list parts first" schema. Leg beside the body, nose between the eyes.

Scripts (written for a Mac with absolute scratch paths; adapt the paths):
- `run4.mjs`: one Sonnet/Opus drawing call with full page + close-up, parts-first schema; prints timing and stroke paths.
- `crop.py`: makes the close-up (crop, enlarge, grid labeled in page units).
- `overlay.py`: draws returned strokes onto a page photo. `sheet.py`: 2x2 comparison sheet.
