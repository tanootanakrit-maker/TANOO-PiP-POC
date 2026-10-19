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
- 1–6 prompt segments visible in PiP (default 3)
- Local project persistence
- Pause → Resume → Stop และ Repeat Take โดยอัดทุกช่วงต่อในงานเดียว และรวมเป็นวิดีโอเดียวเมื่อกด Stop
- Repeat Take ย้อน Teleprompter ไปจุดเริ่มของเทคล่าสุด แล้วเพิ่มช่วงอัดซ้ำต่อท้ายโดยไม่ลบช่วงเดิม
- Bluetooth selfie shutter / ปุ่มเพิ่มเสียง: REC, Pause, Resume และกดสองครั้งขณะ Pause เพื่อ Repeat Take
- Grid และ Level/Horizon overlay ที่เปิดปิดและจำค่าได้
- เลือกจำนวนบรรทัด Teleprompter 1–6 บรรทัด (ค่าเริ่มต้น 3)
- ตรวจ codec จากกล้องจริงก่อนแสดง ProRes RAW; ไม่ใช้ชื่อ RAW กับไฟล์ HEVC/H.264
- ค่า F เป็น simulated aperture เฉพาะ Cinematic ที่ device/API รองรับ

## Important iOS limitation

The Live PiP architecture is used because playback-style PiP is paused by Apple Camera on the tested device. Live PiP does not expose arbitrary custom interactive controls inside the floating system window. Detailed controls remain in the main app.

Voice Follow and Hybrid request microphone access. When Apple Camera is actively recording video, iOS may take exclusive control of the microphone. Hybrid is designed to continue Auto scrolling when Voice becomes unavailable. Auto mode does not require the microphone.
