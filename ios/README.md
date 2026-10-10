# DrawCompanion for iPhone

The AR drawing assistant as a native iPhone app. Put the phone in a headset viewer, look at your paper, and talk. Claude places an outline on the paper for you to trace, changes it when you ask, and clears it 3 seconds after you stop tracing. It never talks back.

No Mac server, no printed template: the phone finds the paper itself and calls Claude directly.

## Run it

1. Open **`ios/DrawCompanionAR.xcodeproj`** in Xcode 16 or later.
2. Click the **DrawCompanionAR** target → **Signing & Capabilities** → choose your **Team** (your Apple ID works; add it under Xcode › Settings › Accounts if the list is empty). If Xcode complains about the bundle identifier, change `com.drawcompanion.ar` to something unique, like `com.yourname.drawcompanion`.
3. Plug in your iPhone (iOS 18+), pick it as the run destination at the top of Xcode, and press **Run** (⌘R). AR needs a real phone; the simulator has no camera.
   - First time only: on the phone, allow Developer Mode (Settings › Privacy & Security), and trust your developer certificate (Settings › General › VPN & Device Management).
4. In the app, tap the **gear** and paste your Claude API key. Without a key, a mock AI draws a sample flower so you can try everything else.

## Using it

The app runs in landscape. Point the camera at your paper until the status says **Page found**.

- **Phone view:** tap the mic or type what you'd say. Good for checking things work.
- **Headset view:** tap **Headset view**, put the phone in the viewer, and talk. A small dot low in each eye shows status: green listening, pulsing blue working, orange can't see the page, grey mic off. Double-tap (press the viewer's button twice) to leave.

| Say something like… | What happens |
|---|---|
| "I'm stuck, maybe a cat on the windowsill?" | A new outline appears where Claude thinks it fits |
| "bigger" / "move it left of the house" / "no, a pine tree" | The outline changes |
| "clear it" / "got it" | The outline goes away |
| Anything else | Nothing |

## How it works

| Part | File |
|---|---|
| Finds the paper (Vision) and pins its corners in the room (ARKit) | `DrawCompanionAR/AR/ARController.swift` |
| Draws the camera and outline, one view or two eyes (Metal) | `DrawCompanionAR/AR/Renderer.swift`, `Shaders.metal` |
| Top-down page photo for Claude, small gray page for tracing | `DrawCompanionAR/AR/PageImaging.swift` |
| Always-on speech (on-device when supported) | `DrawCompanionAR/Speech/SpeechListener.swift` |
| Turns: Haiku decides, Sonnet streams the outline; cancel and restore | `DrawCompanionAR/App/AppModel.swift`, `Core/ClaudeClient.swift`, `Core/TurnBackend.swift` |
| Curve paths and the streaming reader | `DrawCompanionAR/Core/PathFlattener.swift` |
| The 3-second clear | `DrawCompanionAR/Core/CompletionTracker.swift` |
| API key in the Keychain | `DrawCompanionAR/App/Keychain.swift` |

**About the key:** it's stored in the iPhone's Keychain and sent only to api.anthropic.com. That's fine on your own phone. Don't ship this to other people with your key in it; a public app would need a small server holding the key instead.

## Tests

The platform-independent logic (`DrawCompanionAR/Core`) is also a Swift package:

```bash
swift test --package-path ios
```

GitHub Actions runs those tests and builds the app for iPhone on every push (`.github/workflows/checks.yml`).
