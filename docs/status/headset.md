# Headset session status

**Branch: `claude/fervent-turing-1v3ob4`** (based on `ar/headset`)

## In progress
- Core: `Core/HeadsetOptics.swift` (lens model, eye layout, settings), `Core/HeadsetStrokes.swift` (dashes, draw-on reveal, stroke arrival times), tests in `CoreTests/HeadsetTests.swift`.
- Renderer rewrite: offscreen 4x MSAA eye texture, barrel pre-distortion pass, capsule strokes with per-stroke stencil, ring buffers, 120 Hz.

## Requests for the lead
- (pending) see below once the renderer lands.
