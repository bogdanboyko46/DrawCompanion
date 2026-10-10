# Parallel workstreams (tonight, until 5 AM EST)

Goal: DrawCompanion iPhone app (`ios/DrawCompanionAR`) is fully working, robust and impressive: you talk, an outline appears on your paper exactly where it belongs, matched to your drawing's style, locked to the paper with near-zero drift, in a headset view.

Several Claude sessions work at once. Each has its own folder (git worktree) and branch, and owns specific files. The lead merges branches into `claude/sleepy-cori-b7523k` and tests on the iPhone.

## Rules (everyone)

1. **Only edit files you own** (table below). Need a change elsewhere? Message the lead session (`DRAWINGCOMPANION`) with SendMessage: the file, the change, and why. Don't edit it yourself.
2. **Never touch the iPhone.** No `devicectl`, no Xcode Run, no installs. The lead is the only one who installs and tests on the phone (another app shares it too).
3. **Prove it compiles and passes before you hand off:**
   - `swift test --package-path ios` (platform-independent logic in `ios/DrawCompanionAR/Core`, tests in `ios/CoreTests`)
   - `xcodebuild -project ios/DrawCompanionAR.xcodeproj -scheme DrawCompanionAR -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath <a folder in your own scratchpad> build`
   - Put testable logic in `Core/` with tests. Anything that can be checked on the Mac, check on the Mac.
4. **Commit small, push your branch, then message the lead** with what's ready, how you verified it, and what to look for on the phone.
5. Merge the lead branch into yours now and then (`git fetch origin && git merge origin/claude/sleepy-cori-b7523k`) to stay current. Never rewrite history; never push to another session's branch.
6. Debug logging: `print("[DC] …")`. The lead reads these from the phone.
7. API key: `~/DrawCompanion/.env` has `ANTHROPIC_API_KEY` (load with `process.loadEnvFile`). Never print it. Keep total API spend for your workstream under $5.
8. Commit messages end with: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

## Ownership

| Session (folder, branch) | Owns | Focus |
|---|---|---|
| **Lead**: `~/DrawCompanion-AR`, `claude/sleepy-cori-b7523k` | `AR/ARController.swift`, `AR/PageImaging.swift`, `Core/DrawingAligner.swift`, `Core/CompletionTracker.swift`, `App/AppModel.swift`, `.github/`, merges | Paper tracking, drift correction, auto-clear, on-device testing |
| **Headset**: `~/DrawCompanion-headset`, `ar/headset` | `AR/Renderer.swift`, `AR/Shaders.metal`, `AR/CameraView.swift`, `UI/HeadsetOverlay.swift`, new files under `AR/Headset*` or `Core/Headset*` | The headset viewing experience |
| **AI**: `~/DrawCompanion-ai`, `ar/ai` | `Core/Prompts.swift`, `Core/ClaudeClient.swift`, `Core/TurnBackend.swift`, `Core/PageRegion.swift`, `Core/PageEnhance.swift`, `Core/InkStyle.swift`, `server/`, new `eval/` | Placement accuracy, speed, request understanding |
| **UX**: `~/DrawCompanion-ux`, `ar/ux` | `Speech/`, `UI/ContentView.swift`, `UI/SettingsView.swift`, `App/Keychain.swift`, `App/DrawCompanionApp.swift`, assets/app icon, `README.md`, `ios/README.md`, `docs/` (except this file) | First run, listening, settings, polish, docs |

`Core/Outline.swift` (shared types) belongs to the lead; ask before changing it.
