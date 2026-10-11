# DrawCompanion for iPhone

Draw on real paper with your phone in a headset viewer. Just talk ("I'm stuck, maybe a cat on the windowsill?"). Claude places an outline on your paper in your pencil's color and thickness, changes it when you ask, and clears it 3 seconds after you stop tracing. It never talks back.

No server and no printed template: the phone finds the paper itself and calls Claude directly.

## Install it on your iPhone

You need a Mac with **Xcode 16 or later** (free on the Mac App Store) and an iPhone with **iOS 18 or later**.

1. Open **`ios/DrawCompanionAR.xcodeproj`** (double-click it in Finder).
2. In the left sidebar click the blue **DrawCompanionAR** project, then the **DrawCompanionAR** target → **Signing & Capabilities** → pick your **Team**. Your Apple ID works: if the list is empty, add it under **Xcode › Settings › Accounts**. If Xcode says the bundle identifier is taken, change `com.drawcompanion.ar` to something unique, like `com.yourname.drawcompanion`.
3. Plug in your iPhone, choose it at the top of the Xcode window, and press **Run** (⌘R). The simulator won't work: AR needs a real camera.
   - First time only, on the phone: turn on **Developer Mode** (Settings › Privacy & Security), and trust your certificate (Settings › General › VPN & Device Management).

## First launch

A short welcome walks you through it (you can skip it; it's under Settings › Help later):

1. **What it does.**
2. **Three permissions:** camera (to see the paper), microphone and speech recognition (to hear you; speech is turned into text on the phone when it can be). Nothing is recorded or saved.
3. **Your Claude API key.** Create one at [console.anthropic.com](https://console.anthropic.com) › API keys, copy it, and tap **Paste** then **Check & save**. The app checks it with one free request and tells you if it's wrong. Or skip: a sample AI draws a flower so you can try everything else.
4. **Point at your paper** until the frame turns green.
5. **What to say.**

## Using it

The app runs in landscape. The microphone is on whenever the app is open.

**Phone view** (for setup and trying things): the pill at the top left says what's happening: *Looking for paper*, *Listening*, *Working on it*, or *Mic off*. What you're saying shows faintly at the bottom as you speak. You can also type. If something needs fixing (no connection, key rejected, microphone off) a banner says so, with a button to fix it.

**Headset view:** tap **Headset view**, slide the phone into the viewer, and talk. A small dot low in each eye shows status: green listening, pulsing blue working, orange can't see the page, grey mic off. Double-tap the screen (or press the viewer's button twice) to come back.

| Say something like… | What happens |
|---|---|
| "I'm stuck, maybe a cat on the windowsill?" | A new outline appears where Claude thinks it fits |
| "bigger" / "move it left of the house" / "no, a pine tree" | The outline changes |
| "clear it" / "got it" | The outline goes away |
| Anything else | Nothing |

A phrase is sent after a short pause (1 s by default; a phrase that trails off, like "a cat on the…", waits an extra second). Listening pauses for phone calls and Siri and when you leave the app, and picks up again on its own.

**Settings** (gear, top right): your API key (masked; check, replace or remove it), **Sample AI** (no API calls), the pause before a phrase is sent, headset adjustments, and the welcome screens again.

## How it works

| Part | File |
|---|---|
| Finds the paper (Vision) and pins its corners in the room (ARKit) | `DrawCompanionAR/AR/ARController.swift` |
| Draws the camera and outline, one view or two eyes (Metal) | `DrawCompanionAR/AR/Renderer.swift`, `Shaders.metal` |
| Top-down page photo for Claude, small gray page for tracing | `DrawCompanionAR/AR/PageImaging.swift` |
| Always-on speech: restarts itself, survives calls and backgrounding | `DrawCompanionAR/Speech/SpeechListener.swift` |
| When a phrase is finished | `DrawCompanionAR/Core/PhraseEndpointer.swift` |
| Turns: Haiku decides, Sonnet streams the outline; cancel and restore | `DrawCompanionAR/App/AppModel.swift`, `Core/ClaudeClient.swift`, `Core/TurnBackend.swift` |
| Curve paths and the streaming reader | `DrawCompanionAR/Core/PathFlattener.swift` |
| The 3-second clear | `DrawCompanionAR/Core/CompletionTracker.swift` |
| Welcome, phone view, settings | `DrawCompanionAR/UI/` |
| API key in the Keychain, and checking it | `DrawCompanionAR/App/Keychain.swift`, `Core/APIKeyCheck.swift` |

**About the key:** it's stored in the iPhone's Keychain and sent only to api.anthropic.com. That's fine on your own phone. Don't give this build to other people with your key in it; a public app would need a small server holding the key instead.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Looking for paper" never goes away | Light the page well; a white sheet on a darker table works best. Get the whole page in view once. |
| Banner: microphone or speech is off | Tap **Open Settings** and allow both, then come back. |
| Banner: key rejected | Settings › **Replace key**, paste a fresh one from the console. |
| It cuts you off mid-sentence | Settings › Listening: raise **Pause before sending**. |
| It's slow to react after you stop talking | Lower **Pause before sending**. |
| Debug output | Run from Xcode and read the console; app lines start with `[DC]`. |

## Tests

The platform-independent logic (`DrawCompanionAR/Core`) is also a Swift package:

```bash
swift test --package-path ios
```

GitHub Actions runs those tests and builds the app for iPhone on every push (`.github/workflows/checks.yml`).
