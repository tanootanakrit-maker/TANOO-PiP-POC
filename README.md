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
- Pause → Resume → Stop ยังรวมทุกช่วงใน Take เดียวเป็นวิดีโอไฟล์เดียว
- New Take และ Repeat Take จะบันทึก Take เดิมลง Photos ก่อน แล้วสร้างไฟล์ Take ใหม่โดยไม่ลบไฟล์ก่อนหน้า
- ชื่อต้นฉบับใช้ `[Script] Take 1.mov`, `[Script] Take 2.mov` และจำเลขล่าสุดแยกตามชื่อ Script
- Bluetooth selfie shutter / ปุ่มเพิ่มเสียงตอบสนองทันที: กดระหว่าง REC เพื่อ Pause, กดหลัง Pause เพื่อ Resume และกดซ้ำระหว่าง Countdown เพื่อบันทึก Take เดิมแล้วเริ่ม Repeat Take เป็นไฟล์ใหม่
- Grid และ Level/Horizon overlay ที่เปิดปิดและจำค่าได้
- เลือกจำนวนบรรทัด Teleprompter 1–6 บรรทัด (ค่าเริ่มต้น 3)
- ตรวจ codec จากกล้องจริงก่อนแสดง ProRes RAW; ไม่ใช้ชื่อ RAW กับไฟล์ HEVC/H.264
- เมนูฉากหลังเบลอแสดงตลอด พร้อมปุ่มเปิด CINE และปรับความละเอียด/30 FPS ไปยังค่าที่อุปกรณ์รองรับอัตโนมัติ
- ค่า F เป็น simulated aperture เฉพาะ Cinematic ที่ device/API รองรับ และแสดงบนแถบสถานะขณะใช้งาน
- iOS 15–25 รองรับ System Portrait Effect จาก Control Center พร้อมตรวจสถานะ Active และเลือก Format/FPS ที่รองรับอัตโนมัติ
- TANOO Blur ทำ Person Segmentation และเบลอพื้นหลังลงในวิดีโอไฟล์สุดท้ายภายในแอป ไม่ต้องมีปุ่ม Portrait ใน Control Center
- ปรับระดับ TANOO Blur ได้ 15–100% ใช้ VIDEO 1080p 30fps เพื่อความเสถียร และประมวลผลวิดีโอรวมทุกเทคหลัง Stop โดยยังคงเสียงไว้
- Preview กล้องหน้าเป็นกระจก แต่ recording connection บันทึกภาพจริงที่ตัวหนังสืออ่านถูกด้าน โดยไม่ export พลิกภาพภายหลัง
- PRO Manual มี Auto/Manual, Manual Focus, Exposure Compensation, ISO, Shutter, Temperature/Tint, Zoom และ Auto reset พร้อม clamp ตาม Format จริง

## Important iOS limitation

The Live PiP architecture is used because playback-style PiP is paused by Apple Camera on the tested device. Live PiP does not expose arbitrary custom interactive controls inside the floating system window. Detailed controls remain in the main app.

Voice Follow and Hybrid request microphone access. When Apple Camera is actively recording video, iOS may take exclusive control of the microphone. Hybrid is designed to continue Auto scrolling when Voice becomes unavailable. Auto mode does not require the microphone.
