# Shaken — macOS asset kit v1

ชุด asset เวกเตอร์ที่วาดใหม่จากแนวคิด Shaken เพื่อใช้ในแอปจริง ไม่ใช่การครอปภาพ mockup

## ติดตั้งใน Xcode

1. ลากโฟลเดอร์ `Assets.xcassets` เข้าโปรเจกต์ หรือคัดลอกชุด `.imageset` และ `.appiconset` เข้า asset catalog เดิม หากมี AppIcon อยู่แล้ว ให้เลือกแทนที่อย่างตั้งใจเพื่อไม่ให้ชื่อซ้ำ
2. เลือก AppIcon ใน Target > General > App Icons หากโปรเจกต์ใช้ asset catalog อยู่แล้ว
3. ใช้ `ShakenMenuBarTemplate` สำหรับ NSStatusItem และตั้ง `isTemplate = true` ตาม Integration.swift ขนาดแนะนำ 18 × 18 pt
4. ใช้ชื่อ Convert, Compress, Metadata, Preview, CopyName, Downloads ฯลฯ ผ่าน Image("Convert") ใน SwiftUI และกำหนดสีที่ runtime

## ไฟล์ที่ให้

- `AppIcon/Shaken.icns`: macOS icon container ขนาดสูงสุด 1024 px
- `AppIcon/Shaken.iconset`: 16, 32, 128, 256, 512 pt ที่ 1x/2x ตาม macOS iconset
- `AppIcon/Shaken-{size}.png`: 16, 18, 20, 24, 32, 40, 48, 64, 96, 128, 256, 512, 1024 px; RGBA มีพื้นที่ว่างรอบกรอบไอคอน
- `MenuBar`: monochrome PDF vector และ PNG 16, 18, 20, 22, 24, 32 pt ที่ 1x/2x/3x ภาพดำพื้นหลังโปร่งใสเป็น template mask ไม่ใช่ไอคอนหายหรือเรนเดอร์ผิด
- `Glyphs`: ไอคอนคำสั่ง 16 แบบ เป็น PDF vector และ PNG 16, 20, 24, 32 pt ที่ 1x/2x/3x
- `Sources`: SVG ต้นฉบับของ AppIcon, Menu Bar และ glyph ทุกตัว แก้ไขสี รูปทรง และ export ต่อได้
- `Wheel/Dark`, `Wheel/Light`: พื้นวงกลม 6 ช่อง, ช่องปกติ/selected แยกชิ้น, ปุ่มกลาง, shelf เป็น SVG
- `Assets.xcassets`: AppIcon และ PDF template image sets พร้อม Contents.json
- `Integration.swift`: ตัวอย่างโหลดภาพ Template, SwiftUI wheel และ NSStatusItem
- `Preview.png`: ภาพรวมที่เรนเดอร์จาก asset จริงในชุด
- `build_assets.py`: สคริปต์สร้างชุดไฟล์ใหม่ ต้องมี Python 3, Pillow, Inkscape และฟอนต์ DejaVu Sans สำหรับ preview

## Menu UI

Wheel ใช้ canvas มาตรฐาน 420 × 420 pt วงนอก r=202, วงใน r=72, ปุ่มกลาง r=67; แต่ละช่องมีช่วงมุม 57.6° โดยเหลือร่อง 2.4° ระหว่างช่อง ลำดับเริ่มจากด้านบนแล้วตามเข็มนาฬิกา: Convert, Compress, Metadata, Preview, CopyName, Downloads

SVG ของช่องแต่ละชิ้นใช้ canvas เต็มวง เพื่อซ้อนกันได้ตรงกัน ไม่ใช่ภาพที่ crop ชิดรูปทรง ในแอปจริงควรวาด Path ตาม Integration.swift เพื่อเปลี่ยนขนาดและ hover ได้ ส่วน SVG เป็นทรัพยากรสำหรับแก้แบบหรือใช้กับ renderer ที่รองรับ SVG เพราะ NSImage ไม่ได้โหลด SVG จาก asset catalog แบบ PDF โดยตรง

ใส่ชื่อคำสั่งเป็น Text ที่ runtime เพื่อแปลภาษาและปรับขนาดได้ ไอคอนและพื้นหลังจึงไม่มีตัวอักษรฝังอยู่ ใช้ป้ายชื่อที่ชัดเจน เช่น Remove metadata สำหรับคำสั่งลบข้อมูล แทน Metadata หากพื้นที่พอ

สีหลัก: accent #7D89ED, dark surface #20283D, light surface #F5F7FF, text #F4F5FF บน dark และ #182035 บน light; ใช้ accent กับช่องที่เลือกโดยไม่เปลี่ยนระยะหรือขนาด hit target

พื้น SVG เป็นสีโปร่งใสแบบคงที่ การ blur พื้นหลังจริงต้องใช้ Material/NSVisualEffectView ในแอป ตัวอย่าง SwiftUI ใช้ .ultraThinMaterial ให้พื้นช่อง

## การตรวจสอบ

ตรวจการเปิด PNG ทุกไฟล์, ขนาด AppIcon, icon container .icns, รายการอ้างอิงใน Contents.json และภาพ preview แล้ว ยังไม่ได้ build หรือทดสอบใน Xcode/macOS จึงควรตรวจ Menu Bar ที่ความละเอียด 1x/2x และแถบเมนูสว่าง/มืดบนเครื่องจริงก่อน release
