# Parallel workstreams (tonight, until 5 AM EST)

Goal: DrawCompanion iPhone app (`ios/DrawCompanionAR`) is fully working, robust and impressive: you talk, an outline appears on your paper exactly where it belongs, matched to your drawing's style, locked to the paper with near-zero drift, in a headset view.

Several Claude sessions work at once. Each has its own branch and owns specific files. The lead merges branches into `claude/sleepy-cori-b7523k` and tests on the iPhone.

## Rules (everyone)

The three helper sessions run in the cloud (Linux, no Xcode, no access to the user's Mac). The lead runs on the user's Mac with the iPhone attached.

1. **Work only on your branch** (the one your session assigns, else `ar/headset`, `ar/ai` or `ar/ux`; name it at the top of your status file) and **only edit files you own** (table below). Need a change elsewhere? Write it in your status file (rule 5) under "Requests for the lead", with the file and the exact change.
2. **Never try to run the app.** The lead installs and tests every merge on the iPhone.
3. **Verification happens on GitHub's Mac machines.** Every push to `ar/**` or `claude/**` runs the "Checks" workflow (`.github/workflows/checks.yml`): web tests, `swift test --package-path ios` (logic in `ios/DrawCompanionAR/Core`, tests in `ios/CoreTests`), and an unsigned iPhone build. After each push, check the run's result with the GitHub tools and fix failures before moving on. Keep pushes small so failures are easy to pin down. Put testable logic in `Core/` with tests.
4. Merge the lead branch into yours now and then (`git fetch origin claude/sleepy-cori-b7523k && git merge origin/claude/sleepy-cori-b7523k`). Never rewrite history; never push to another session's branch.
5. **Report through a status file on your branch: `docs/status/<headset|ai|ux>.md`.** Keep it current: what's done and verified (with the CI run), what to look for on the phone, what's next, and "Requests for the lead". The lead reads it every ~30 minutes and merges what's ready. Mark something "READY TO MERGE" only when CI is green.
6. Debug logging: `print("[DC] …")`. The lead reads these from the phone.
7. API key: only if the cloud environment provides `ANTHROPIC_API_KEY`. Never print it. Keep total API spend under $5.
8. Commit messages end with: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

## Ownership

| Session (folder, branch) | Owns | Focus |
|---|---|---|
| **Lead** (user's Mac): `claude/sleepy-cori-b7523k` | `AR/ARController.swift`, `AR/PageImaging.swift`, `Core/DrawingAligner.swift`, `Core/CompletionTracker.swift`, `App/AppModel.swift`, `.github/`, merges | Paper tracking, drift correction, auto-clear, on-device testing |
| **Headset** (cloud): `ar/headset` | `AR/Renderer.swift`, `AR/Shaders.metal`, `AR/CameraView.swift`, `UI/HeadsetOverlay.swift`, new files under `AR/Headset*` or `Core/Headset*` | The headset viewing experience |
| **AI** (cloud): `ar/ai` | `Core/Prompts.swift`, `Core/ClaudeClient.swift`, `Core/TurnBackend.swift`, `Core/PageRegion.swift`, `Core/PageEnhance.swift`, `Core/InkStyle.swift`, `server/`, `eval/` | Placement accuracy, speed, request understanding |
| **UX** (cloud): `ar/ux` | `Speech/`, `UI/ContentView.swift`, `UI/SettingsView.swift`, `App/Keychain.swift`, `App/DrawCompanionApp.swift`, assets/app icon, `README.md`, `ios/README.md`, `docs/` (except this file, `docs/prompts/` and other sessions' `docs/status/` files) | First run, listening, settings, polish, docs |

`Core/Outline.swift` (shared types) belongs to the lead; ask before changing it.
