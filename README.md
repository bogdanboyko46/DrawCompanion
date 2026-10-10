# DrawCompanion

An AR drawing assistant. You draw on real paper, and when you're stuck you ask for a suggestion. An outline that matches your drawing's style and colors appears on the paper, locked in place. Trace it, and it fades away.

**New: drawings come to life.** Point the iOS app at a character you drew and it becomes a detailed, rigged, animated 3D character standing on your desk. See **[ios/README.md](ios/README.md)** and the design note **[docs/CHARACTERS.md](docs/CHARACTERS.md)**.

This repo also has a working **"magic window" prototype**: a phone or tablet camera over your page stands in for the headset. It also has a design doc that critiques the concept and lays out the path to a headset version: **[docs/DESIGN.md](docs/DESIGN.md)**.

## How it works

1. **Lock on:** tap the page's four corners once. From then on, everything is computed in paper coordinates.
2. **Ask:** type or hold the mic button and speak. Optionally drag a box to mark where the suggestion should go. Pick a mode:
   - **Outline:** guides plus contours to trace
   - **Guides only:** construction shapes only; you draw the final lines
   - **3 ideas:** three alternatives to flip through on the paper
3. **Suggest:** the page (and only the page; the room is cropped out) is rectified to a top-down image with a labeled grid. Claude returns vector strokes, a palette from your drawing, and short steps.
4. **Trace:** strokes dim as you trace them. Once you've traced most of the outline, it fades out. Hands and lighting changes are ignored.

## Run it

Requires Node 20+.

```bash
npm install

# Try the UI without API calls (returns a canned flower)
npm run mock

# Real suggestions (uses ANTHROPIC_API_KEY or an `ant auth login` profile)
npm start
```

Open http://localhost:8787. Camera access needs a secure context, so `localhost` works on the same machine. To use a phone, serve over HTTPS (for example through a tunnel) and open that URL on the phone.

Optional environment variables: `PORT` (default `8787`), `DRAWCOMPANION_MODEL` (default `claude-opus-5-5`), `DRAWCOMPANION_EFFORT` (default `low`, tuned for response speed).

**Best setup:** prop the phone or tablet on a stand, looking down at the paper, and use even lighting. The prototype assumes the page doesn't move after you tap the corners. Tap **Set corners** again if it does.

## Layout

| Path | What it is |
|---|---|
| `server/suggest.js` | Prompt, output schema, and Claude call; sanitizes returned strokes |
| `server/index.js` | Static file server and `POST /api/suggest` |
| `server/mock.js` | Canned response for offline UI work |
| `server/character/` | Drawing → 3D character pipeline: Claude art director, Meshy client, resumable jobs, Blender USDZ packer, mock backends |
| `ios/` | Native ARKit + RealityKit app that brings drawings to life (Xcode project) |
| `scripts/make_mock_character.py` | Builds the rigged sample character used in mock mode |
| `public/geometry.js` | Homography (paper ⇄ camera) and page rectification |
| `public/completion.js` | Decides when an outline has been traced (thin-line test, occlusion, lighting) |
| `public/app.js` | Camera, calibration, asking, rendering, fade-out |
| `docs/DESIGN.md` | Critique, improvements, architecture, roadmap |

## Tests

```bash
npm test
```

Covers the homography math, page rectification, and the completion tracker: tracing, partial progress, stray ink, a hand over the outline, page-wide changes, and lighting shifts. The character tests cover the full pipeline against mock backends: every stage, the static fallback for non-humanoids and failed rigs, resuming without re-paying, the concept repaint, and early rejection of pages with no character.
