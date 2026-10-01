# TANOO Teleprompter

Native iPhone teleprompter that uses Apple's Live Picture in Picture so the prompt can remain visible above the original Camera app without being burned into the recorded video.

## Current build

- Live PiP proven on-device above Apple Camera
- Script editor
- Project save/load
- Export .txt
- Auto mode
- Voice Follow (Thai)
- Hybrid mode: Auto base + Voice advance
- Previous / Start-Pause / Next
- Font size and line spacing
- Text alignment and color presets
- Auto speed
- Vertical prompt position
- Black overlay opacity
- 2–4 prompt segments visible in PiP
- Local project persistence

## Important iOS limitation

The Live PiP architecture is used because playback-style PiP is paused by Apple Camera on the tested device. Live PiP does not expose arbitrary custom interactive controls inside the floating system window. Detailed controls remain in the main app.

Voice Follow and Hybrid request microphone access. When Apple Camera is actively recording video, iOS may take exclusive control of the microphone. Hybrid is designed to continue Auto scrolling when Voice becomes unavailable. Auto mode does not require the microphone.


v3.0.1 validation: serialized REC start after countdown and visible storage/session preflight messages.
