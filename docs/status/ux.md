# UX status

**Branch: `claude/dreamy-ramanujan-f4loae`** (based on `ar/ux`)

## Done — READY TO MERGE (CI green: [run 38098167255](https://github.com/bogdanboyko46/DrawCompanion/actions/runs/38098167255), commit `c44c68a`, includes a merge of the lead branch at `5c07ad2`)

| Item | Files | CI |
|---|---|---|
| Listening: adaptive phrase end, interruptions, backgrounding, task limit, retries | `Speech/SpeechListener.swift`, `Core/PhraseEndpointer.swift` (+ tests) | green |
| API key check (one free `GET /v1/models` request) | `Core/APIKeyCheck.swift` (+ tests) | green |
| First-run welcome (5 short steps, skippable, once) | `UI/OnboardingView.swift` (new), `App/DrawCompanionApp.swift`, `UI/ContentView.swift` | green |
| Phone view: status pill, live transcript, fixable error banners, offline detection | `UI/ContentView.swift` | green |
| Settings: masked key (check/replace/remove), Sample AI toggle, pause slider, headset section, show welcome again | `UI/SettingsView.swift` | green |
| App icon + launch background color | `Assets.xcassets/` (new; picked up by the synchronized folder) | green |
| Docs | `ios/README.md`, `README.md` | green |

New files I created (no one else owns them): `UI/OnboardingView.swift`, `Core/PhraseEndpointer.swift`, `Core/APIKeyCheck.swift`, `CoreTests/PhraseEndpointerTests.swift`, `CoreTests/APIKeyCheckTests.swift`, `Assets.xcassets/`.

## What to look for on the phone

- **First launch** shows the welcome over a dimmed camera. To see it again: Settings › Help › Show the welcome screens again.
  - Permissions are asked one at a time on the second screen, not at launch. The camera (`model.start()`) starts once the camera is allowed or the welcome ends.
  - Key screen: paste a wrong key → "That key was rejected…"; a good key → saved and continues. Offline → saved with a note.
  - Paper screen: live camera, dashed frame turns green with a check when `model.pageFound`.
- **The mic now turns on by itself** after the welcome and at every launch (only if mic + speech are already allowed; never prompts). Mic button still toggles it.
- **Phone view:** pill = Looking for paper (orange) / Listening (green) / Working on it (pulsing cyan) / Mic off / Paused. Live words appear faintly at the bottom while you talk; the sent phrase lingers 3 s. Outline hide button only appears when there's an outline. "Sample AI" chip shows in mock mode.
- **Error banners:** airplane mode → "You're offline…"; bad key → "Fix key" opens Settings; mic denied → "Open Settings"; speech unavailable → "Retry"; call/Siri → "Listening paused (call or Siri)".
- **Listening logs** (`[DC] speech: …` and `[DC] phrase (pause, 2.3s, longest gap 0.62s): …`). Please send me a few `phrase` lines: the "longest gap" values tell whether the 1.0 s pause is right. Settings › Listening also shows the typical value after 3 phrases.
- Test: start a phone call or Siri mid-session → pill says Paused, comes back after. Plug/unplug headphones → restarts. Leave app and come back → resumes. Stay silent > 1 min → keeps listening (idle tasks are replaced every 50 s).

## Listening details

- A phrase ends after **1.0 s** of silence (was 1.2 s), or **2.0 s** if it ends mid-thought ("a cat on the", "um", trailing comma). Adjustable in Settings (0.6–2.0 s, key `dc.speech.pause`). Filler-only phrases ("um.") are dropped. Phrases are cut at 40 s.
- One recognition task per phrase; the next request takes over the audio before the old one closes (no lost words between phrases).
- Errors: routine ones (no speech, cancelled) restart immediately; others back off 1→16 s; after 4 in a row the phone view says it's retrying. Recognizer availability changes are followed.
- Interruptions (calls, Siri), route changes (headphones), media-services reset, engine configuration change, background/foreground are all handled; "wanted" is remembered so it resumes on its own.

## Headset settings

Settings › Headset uses the keys from the headset session (`HeadsetOptics.Key`, branch `claude/fervent-turing-1v3ob4`): a "Correct lens distortion" toggle plus sliders for `headset.zoom`, `headset.lensSeparationMM`, `headset.verticalOffsetMM`, `headset.fieldOfViewDegrees`, `headset.k1`, `headset.k2`, `headset.screenToLensMM`, and "Reset to defaults". Defaults match `HeadsetOptics()`. The keys are plain strings in `HeadsetOption.all` (`UI/SettingsView.swift`), so my branch builds without theirs; until their renderer is merged the sliders save values nothing reads yet.

## Next
- Tune the pause from the lead's `[DC] phrase` logs.
- Keep merging the lead branch; follow up on any phone feedback.

## Requests for the lead

1. **Sample AI toggle** (`App/AppModel.swift`), so the toggle works with a key saved:
   ```swift
   func refreshKey() {
       usingMock = Keychain.apiKey == nil || UserDefaults.standard.bool(forKey: AppSettings.mockMode)
   }
   private func makeBackend() -> TurnBackend {
       if !usingMock, let key = Keychain.apiKey { return ClaudeBackend(client: ClaudeClient(config: .init(apiKey: key))) }
       return MockBackend()
   }
   ```
2. **App icon** (`ios/DrawCompanionAR.xcodeproj/project.pbxproj`, both target configs `A7B000000000000000000203` and `…204`): add
   `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;`
   Without it the asset catalog builds but the icon isn't used.
3. **Launch screen** (dark instead of a white flash): in the same two configs replace
   `INFOPLIST_KEY_UILaunchScreen_Generation = YES;` with `INFOPLIST_FILE = Info.plist;` and add `ios/Info.plist` (outside the synchronized `DrawCompanionAR/` folder, so it isn't copied as a resource):
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>UILaunchScreen</key>
       <dict>
           <key>UIColorName</key>
           <string>LaunchBackground</string>
       </dict>
   </dict>
   </plist>
   ```
   (`GENERATE_INFOPLIST_FILE = YES` stays; Xcode merges the two.)
4. Optional, friendlier permission prompts (pbxproj, both configs):
   - `INFOPLIST_KEY_NSMicrophoneUsageDescription = "DrawCompanion listens while it's open so you can just say what you'd like drawn. Nothing is recorded.";`
   - `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription = "DrawCompanion turns what you say into text, on this iPhone when it can, to understand what to draw.";`
5. Optional (`App/AppModel.swift`, `init`): the `.unavailable` case reports "Speech recognition isn't available right now." on every retry; the phone view already shows a banner with a Retry button, so this can be dropped or kept as is.
