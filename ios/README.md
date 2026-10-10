# DrawCompanion 3D (iOS)

Draw a character on paper, point your iPhone or iPad at it, and tap **Bring it to life**. The drawing peels off the page, turns into a painted 3D concept, then bursts into a rigged, animated character that stands on your desk. It looks at you, wanders around, waves when you come close, and walks to wherever you tap.

## Run it

1. **Start the companion server** on your Mac, from the repo root:

   ```bash
   npm install
   npm run mock     # no API keys: every drawing becomes "Doodle", the sample character
   # or
   npm start        # real characters (see "Server setup" below)
   ```

2. **Open `ios/DrawCompanion3D.xcodeproj`** in Xcode 16 or later. Choose your team under *Signing & Capabilities* and run it on a device with iOS 18 or later. ARKit needs a real device, not the simulator.

3. In the app, tap the **gear** and enter your Mac's address, for example `http://192.168.1.23:8787` (System Settings › Wi-Fi › Details › IP address). Tap **Test connection**. Both devices must be on the same network.

4. Point the camera at your drawing. When the page outline lights up, tap **Bring it to life**.

## What you'll see

| Moment | What happens |
|---|---|
| Page found | A glowing outline locks onto the paper |
| Capture | A light sweeps the page. The figure is cut out of the photo with Vision |
| Reading (about 15 s) | The cutout lifts off the paper and stands up facing you, with sparkles rising |
| Concept (about 30 s) | The flat drawing cross-fades into a painted 3D render of itself |
| Sculpt, rig, animate (1–3 min) | A card shows each stage, the character's name, and the palette taken from your drawing |
| Ready | The card bursts and the character pops in on the paper with a little overshoot, waves, and says hello |

Once it's alive:

- **Tap the character:** it reacts with a jump, a wave, or a line.
- **Tap the table:** it turns, then walks over. It won't walk off the edge of the desk.
- **Pinch:** resize it.
- **Walk up to it:** friendly characters wave when you get close. Shy ones don't.
- **Camera / record buttons:** take a photo or record a video to share.
- **Grid button:** every character you've made. Tap one to bring it back.

Characters the auto-rigger can't take (four-legged animals, blobs, objects) still come to life. They breathe, hop when they walk, and spin when they're happy.

## Server setup (real characters)

`npm start` needs three things:

| What | Why | Setup |
|---|---|---|
| `ANTHROPIC_API_KEY` (or `ant auth login`) | Claude art-directs: reads the drawing, writes the character sheet, checks the concept | `export ANTHROPIC_API_KEY=…` |
| `MESHY_API_KEY` | Concept painting, 3D generation, rigging, animation | Get a key at meshy.ai, then `export MESHY_API_KEY=…` |
| Blender's Python module | Packs the rig and all its clips into one USDZ for RealityKit | `python3.13 -m venv ~/.dc-blender && ~/.dc-blender/bin/pip install bpy` then `export DRAWCOMPANION_PYTHON=~/.dc-blender/bin/python` |

The server warns at startup if the packer isn't available. With `DRAWCOMPANION_ANIMATE=0` you don't need Blender at all.

A character costs roughly **50–60 Meshy credits**: about 9 for the concept (plus 9 if it has to be repainted), about 30 for the textured 3D model, a few for rigging, and 3 for each extra animation clip. Walk and run come free with the rig. Check Meshy's current pricing.

Optional environment variables:

| Variable | Default | Effect |
|---|---|---|
| `DRAWCOMPANION_ANIMATE` | `1` | `0` ships every character as a static model with a natural pose: no rigging or animations, no Blender needed, about 1–2 minutes and 10–15 credits less per character |
| `DRAWCOMPANION_IMAGE_MODEL` | `nano-banana-pro` | Concept painter (`nano-banana`, `nano-banana-2`, `gpt-image-2`, …) |
| `DRAWCOMPANION_MESH_MODEL` | `latest` | Meshy 3D model |
| `DRAWCOMPANION_POLYCOUNT` | `50000` | Triangle budget. 30–60k looks great on phones |
| `DRAWCOMPANION_MULTIVIEW` | `1` | Paint front, side and back views for better 3D. Set to `0` for a single view |
| `DRAWCOMPANION_DIRECTOR_EFFORT` | `high` | Claude effort for reading the drawing |
| `DRAWCOMPANION_MAX_JOBS` | `2` | Characters generated at once |
| `DRAWCOMPANION_DATA` | `data/characters` | Where jobs and models are stored |

Jobs survive a server restart: Meshy task ids are saved as soon as they're created, so a restarted server picks up polling instead of paying again.

## Code map

| Path | What it does |
|---|---|
| `App/AppModel.swift` | App state: capture → upload → poll → materialize, library, sharing |
| `AR/SceneController.swift` | ARView setup (plane detection, people occlusion, LiDAR mesh occlusion), live page detection, capture, taps, frame loop |
| `AR/PaperPortal.swift` | The "making of" on the paper: sweep, peel-off cutout, concept cross-fade, burst |
| `Capture/PageScanner.swift` | Vision document detection, perspective correction to the paper's measured proportions, paper-white balance, figure cutout |
| `Character/CharacterActor.swift` | Loads the USDZ, normalizes size, slices the clip timeline, runs the behavior brain and procedural motion |
| `Networking/` | Server API, job models, on-device library |
| `UI/` | SwiftUI overlays: capture panel, generation card, speech bubbles, library, settings |

## Troubleshooting

- **"Couldn't reach the server":** use the Mac's IP, not `localhost`. Check that the Mac's firewall allows Node, and that iOS asked for Local Network permission (Settings › Privacy › Local Network).
- **The page outline doesn't appear:** use even light and a contrasting table, and get the whole sheet in view. You can still tap the button: it then uses the middle of the frame.
- **The character is tiny or huge:** pinch. Default height is about 85% of the paper's long side.
- **It came out static:** the drawing wasn't humanoid enough for the auto-rigger (the library tile says "Static model"). Drawing arms clearly away from the body helps.
