# DrawCompanion

An AR drawing assistant. You draw on real paper wearing a lightweight headset (your phone in a head-mounted viewer). When you're stuck, look at the spot, box it with two taps, and say what you want. An outline matched to your drawing appears in the box. Not right? Tap and say what to change. Once you stop drawing on it for 3 seconds, it clears.

Design, decisions and remaining risks: **[docs/DESIGN.md](docs/DESIGN.md)**.

## Setup

1. **Print the template:** open `/template.html` (A4 or US Letter) and print at 100%. Draw inside the grey frame. The black squares let the app find the page from any angle, so keep them uncovered when you can.
2. **Run the server** (Node 20+):

   ```bash
   npm install
   npm run mock   # canned suggestion (a flower), no API calls; for trying the flow
   npm start      # real suggestions (uses ANTHROPIC_API_KEY or an `ant auth login` profile)
   ```

3. **Open it on the phone.** Camera and microphone access need a secure context: `localhost` on the same machine, or HTTPS (for example through a tunnel) from the phone. Chrome on Android gives the best results (speech input, fullscreen, landscape lock).

## Using it

**Headset view** (tap *Headset view*, put the phone in the viewer):

| You're… | Tap the viewer button to… |
|---|---|
| Ready | Start a box where the dot is |
| Boxing | Finish the box at the dot; it then listens for your request |
| Listening | Stop listening |
| Seeing an outline | Say a change: "smaller", "facing left", "next idea", "hide" |

Say "some ideas for…" to get 3 options, or "just the guides for…" for construction lines only.

**Phone view:** drag a box on the page, then type or tap 🎤. After a suggestion appears, use *Change it* for feedback.

Optional environment variables: `PORT` (default `8787`), `DRAWCOMPANION_MODEL` (default `claude-opus-5-5`), `DRAWCOMPANION_EFFORT` (default `low`, tuned for response speed).

## Layout

| Path | What it is |
|---|---|
| `server/suggest.js` | Prompt, output schema, Claude call (requests and feedback revisions); sanitizes strokes |
| `server/index.js` | Static file server and `POST /api/suggest` |
| `server/mock.js` | Canned response for trying the flow without API calls |
| `public/app.js` | Camera, headset/phone views, look-and-tap, voice, requests, rendering |
| `public/tracking.js` | Finds the template's markers every frame and computes the page pose |
| `public/board.js` | Template geometry: frame size and marker positions in paper units |
| `public/template.html` | The printable template |
| `public/completion.js` | Decides when to clear the outline (3 s after you stop tracing it) |
| `public/geometry.js` | Homography math and top-down page rectification |
| `public/vendor/js-aruco2/` | Marker detection library (MIT) |

## Tests

```bash
npm test
```

Covers the homography math, page tracking from rendered templates (full view, mostly covered, downscaled, out of view), and the clearing rule: the 3-second countdown, restarts on new ink, waiting until tracing starts, hands, lighting changes and tracking jitter.
