# DrawCompanion

An AR drawing assistant. You draw on real paper wearing a lightweight headset (your phone in a head-mounted viewer). The microphone is always on: just talk ("I'm stuck, maybe a cat on the windowsill?"). The AI never talks back. It draws an outline on your paper wherever it fits best, changes it when you say so ("bigger, facing left"), clears it when asked, and ignores everything else you say. Once you stop drawing on the outline for 3 seconds, it clears.

Design, decisions and remaining risks: **[docs/DESIGN.md](docs/DESIGN.md)**.

## Two ways to run it

- **iPhone app (recommended): [ios/README.md](ios/README.md).** Open `ios/DrawCompanionAR.xcodeproj` in Xcode and run it on your iPhone. A short welcome asks for camera and microphone access and your Claude API key (checked on the spot). The phone finds the paper on its own (no printed template), listens with Apple's speech recognition, and calls Claude directly. No server needed.
- **Web version (below):** a Node server plus a browser page. Needs the printed template. Handy for trying ideas quickly on any phone or laptop.

## Setup

1. **Print the template:** open `/template.html` (A4 or US Letter) and print at 100%. Draw inside the grey frame. The black squares let the app find the page from any angle, so keep them uncovered when you can.
2. **Add your API key** (Mac): this opens the key file in TextEdit. Paste your key right after `ANTHROPIC_API_KEY=`, press ⌘S, and close it.

   ```bash
   cp .env.example .env
   open -e .env
   ```

   `.env` is ignored by git, so the key never gets committed. The server reads it on start; a variable already set in your shell takes precedence.
3. **Run the server** (Node 20.12+):

   ```bash
   npm install
   npm run mock   # canned AI (draws a flower, reacts to "bigger"/"smaller"/"clear"), no API calls
   npm start      # real AI (key from .env, or an `ant auth login` profile)
   ```

4. **Open it on the phone.** Camera and microphone access need a secure context: `localhost` on the same machine, or HTTPS (for example through a tunnel) from the phone. Chrome on Android gives the best results (speech input, fullscreen, landscape lock).

## Using it

**Headset view:** tap *Headset view*, allow the microphone, and put the phone in the viewer. From then on it's all speech:

| Say something like… | What happens |
|---|---|
| "I'm stuck, what could go here?" / "add a cat on the windowsill" | A new outline appears where the AI thinks it fits |
| "bigger" / "move it left of the house" / "no, a pine tree" | The current outline changes |
| "clear it" / "got it" | The outline goes away |
| Anything else (thinking aloud, talking to someone) | Nothing |

A small dot low in each eye shows status: green listening, pulsing blue working, orange can't see the page, grey microphone off. Exit fullscreen to leave the headset view.

**Phone view:** tap *Start listening*, or type what you'd say and press Enter.

**Which AI:** every phrase first goes to **Claude Haiku 5.5**, which decides whether it's a request (fast, text only, a fraction of a cent). Only requests to draw or change something go on to **Claude Sonnet 5.5**, which sees the page and draws the outline. Lines are streamed to the headset as they're written, so the first ones appear within a few seconds and the rest fill in.

Optional environment variables: `PORT` (default `8787`), `DRAWCOMPANION_FILTER_MODEL` (default `claude-haiku-5-5`), `DRAWCOMPANION_DRAW_MODEL` (default `claude-sonnet-5-5`), `DRAWCOMPANION_DRAW_EFFORT` (default `low`, tuned for response speed), `DRAWCOMPANION_MOCK_DELAY_MS` (mock mode only: simulated AI latency).

## Layout

| Path | What it is |
|---|---|
| `server/suggest.js` | The two AI stages: Haiku filter (new / revise / hide / ignore), then streamed Sonnet drawing for new and revise |
| `server/path.js` | Turns the model's compact curve paths into drawable lines; picks finished strokes out of the stream |
| `server/index.js` | Static file server and `POST /api/turn`, streamed as newline-delimited events (cancels the model call if a newer turn supersedes it) |
| `server/mock.js` | Canned decisions for trying the flow without API calls |
| `public/app.js` | Camera, headset/phone views, always-on voice, turns, rendering |
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

Covers the two-stage AI flow (against a fake API: chatter stops at Haiku, requests stream strokes from Sonnet in order), the curve format and stream reader, the homography math, page tracking from rendered templates (full view, mostly covered, downscaled, out of view), and the clearing rule: the 3-second countdown, restarts on new ink, waiting until tracing starts, hands, lighting changes and tracking jitter.
