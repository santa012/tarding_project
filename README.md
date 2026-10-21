# GoldTrendEA Project

ชุด Expert Advisor (EA) สำหรับ MetaTrader 5 เทรด **ทอง (XAUUSD/GOLD), EURUSD, USDJPY, ETHUSD**
พร้อม **เว็บแดชบอร์ด** สำหรับติดตามผลการเทรดแบบเรียลไทม์

> **คำเตือนสำคัญ:** โค้ดในโปรเจกต์นี้มีทั้งตัวที่ "มี Stop Loss" (ปลอดภัยกว่า) และ **"ไม่มี Stop Loss" (NoSL)**
> ซึ่งเสี่ยงสูงมาก — ขาดทุนต่อไม้ไม่มีเพดานจำกัด อ่านคำเตือนในแต่ละไฟล์ก่อนใช้งานเสมอ
> ทดสอบบนบัญชี **Demo** เท่านั้นก่อนตัดสินใจใช้เงินจริง

---

## โปรแกรมที่ต้องติดตั้ง

| โปรแกรม | ใช้ทำอะไร | จำเป็นไหม |
|---|---|---|
| **MetaTrader 5** (เวอร์ชันของโบรกเกอร์ เช่น XM Global MT5) | รัน EA จริง, คอมไพล์โค้ดผ่าน MetaEditor ที่แถมมาด้วย | ✅ จำเป็น |
| **Docker Desktop** | รันเว็บแดชบอร์ด (Postgres + API + เว็บ) | ✅ จำเป็น (เฉพาะถ้าจะใช้แดชบอร์ด) |
| **WSL2** (Windows Subsystem for Linux) | Docker Desktop บน Windows ต้องใช้เป็น backend | ✅ จำเป็น (Docker จะไม่ทำงานถ้าไม่มี) |
| PowerShell 5.1+ | รันสคริปต์ติดตั้ง/แพ็คโปรเจกต์ | มีมากับ Windows อยู่แล้ว |

**ติดตั้งอัตโนมัติได้ทั้งหมดด้วยคำสั่งเดียว** — ดูหัวข้อ [การติดตั้งแบบรวดเร็ว](#การติดตั้งแบบรวดเร็ว-เครื่องใหม่)

---

## โครงสร้างโปรเจกต์

```
GoldTrendEA_Project/
├── README.md                    <- ไฟล์นี้
├── package_project.ps1           <- แพ็คทั้งโปรเจกต์เป็น .zip ไปติดตั้งเครื่องอื่น
├── MQL5/
│   ├── Experts/GoldTrendEA/      <- ซอร์สโค้ด EA ทั้งหมด (.mq5)
│   └── Scripts/                  <- สคริปต์เสริม (ดึงข้อมูลย้อนหลัง ฯลฯ)
└── dashboard/                     <- เว็บแดชบอร์ด (Docker Compose)
    ├── setup.ps1                  <- ติดตั้ง Docker/WSL2 + รันแดชบอร์ดอัตโนมัติ
    ├── docker-compose.yml
    ├── .env                       <- path ไปยังโฟลเดอร์ Files ของ MT5 (ตั้งอัตโนมัติ)
    ├── db/init.sql                <- schema ฐานข้อมูล
    ├── server/                    <- Express API + ตัวดึง log (importer)
    └── web/                       <- หน้าเว็บ React
```

---

## การติดตั้งแบบรวดเร็ว (เครื่องใหม่)

**บนเครื่องเดิม (แพ็ค):**
```powershell
powershell -ExecutionPolicy Bypass -File .\package_project.ps1
```
ได้ไฟล์ `GoldTrendEA_Project_<วันที่>.zip` คัดลอกไฟล์นี้ไปเครื่องใหม่

**บนเครื่องใหม่ (ติดตั้ง):** แตกไฟล์ zip แล้วเปิด PowerShell แบบ **Run as Administrator** ในโฟลเดอร์ที่แตกไว้
```powershell
cd dashboard
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```
สคริปต์จะ: ติดตั้ง WSL2/Docker Desktop ให้ถ้ายังไม่มี → รอ Docker พร้อม → ค้นหาโฟลเดอร์ MT5 อัตโนมัติ → รัน `docker compose up -d --build` → เปิดแดชบอร์ดให้ที่ `http://localhost:8080`

> **ถ้าเครื่องใหม่ไม่เคยมี WSL2 มาก่อน** Windows จะบังคับให้ **รีสตาร์ทเครื่อง** ก่อน — สคริปต์จะแจ้งเตือนชัดเจน แค่รีสตาร์ทแล้วรันคำสั่งเดิมซ้ำ จะข้ามขั้นตอนที่ทำไปแล้วให้อัตโนมัติ

**ส่วน MT5/EA ต้องทำเอง** (เพราะแต่ละเครื่องใช้บัญชี/โบรกเกอร์ต่างกัน):
1. ติดตั้ง MT5 ของโบรกเกอร์ที่จะใช้ และ login บัญชี (แนะนำ Demo ก่อน)
2. เปิด MT5 → **File → Open Data Folder**
3. คัดลอกไฟล์ `.mq5` จาก `MQL5\Experts\GoldTrendEA\` ในโปรเจกต์ ไปวางที่ `MQL5\Experts\` ของ MT5
4. เปิด **MetaEditor** (กด F4) → เปิดไฟล์ → กด **F7** คอมไพล์ทีละไฟล์ (ต้องไม่มี error)
5. กลับ MT5 → Refresh Navigator → ลาก EA ไปวางบนกราฟที่ตรงกับคู่เงินของมัน → เปิดปุ่ม **Algo Trading** + ติ๊ก **Allow Algo Trading**

---

## รายชื่อ EA ทั้งหมด

### กลุ่มมี Stop Loss (ปลอดภัยกว่า — แนะนำ)

| ไฟล์ | คู่เงิน | Timeframe | ลักษณะ |
|---|---|---|---|
| `GoldFastSafeSL.mq5` | GOLD | M5 | TP $1.5 / SL อิง ATR (ไม่เกิน $2) |
| `EURUSDFastSafeSL.mq5` | EURUSD | M5 | เหมือนกัน ปรับสเปรดให้เหมาะ EURUSD |
| `USDJPYFastSafeSL.mq5` | USDJPY | M5 | เหมือนกัน ปรับสเปรดให้เหมาะ USDJPY |
| `GoldMorning.mq5` | GOLD | M5 | เทรดเฉพาะ 00:00-08:00 (เวลาเซิร์ฟเวอร์) |
| `GoldAfternoon.mq5` | GOLD | M5 | เทรดเฉพาะ 08:00-16:00 |
| `GoldEvening.mq5` | GOLD | M5 | เทรดเฉพาะ 16:00-24:00 |

### กลุ่ม "ไม่มี Stop Loss" (เสี่ยงสูงมาก — ใช้เพื่อการทดลองเท่านั้น)

| ไฟล์ | คู่เงิน | ลักษณะ |
|---|---|---|
| `GoldFastNoSL.mq5` | GOLD | TP $1.5, ไม่มี SL, มี emergency-stop แทน |
| `EURUSDFastNoSL.mq5` | EURUSD | เหมือนกัน |
| `USDJPYFastNoSL.mq5` | USDJPY | เหมือนกัน |
| `ETHUSDFastNoSL.mq5` | ETHUSD | TP $0.50 (สเปรดกว้าง มักไม่ค่อยเข้าไม้) |
| `ETHUSDFastNoSL_5x_Lot04_THB.mq5` | ETHUSD | เปิดได้สูงสุด 5 ไม้, lot 0.04, TP 400 บาท |
| `ETHUSDFastNoSL_5x_Lot02_THB.mq5` | ETHUSD | lot 0.02, TP 10 บาท |
| `ETHUSDFastNoSL_5x_Lot04_TP100THB.mq5` | ETHUSD | lot 0.04, TP 100 บาท |
| `ETHUSDFastNoSL_2x_Lot01_TP100THB.mq5` | ETHUSD | เข้า 2 ไม้ **พร้อมกัน**, lot 0.1, TP 100 บาท |
| `ETHUSDPrecise2x_Lot01_TP1000THB.mq5` | ETHUSD | เหมือนด้านบนแต่เพิ่มตัวกรอง ADX+H1 ให้แม่นขึ้น, TP 1000 บาท |

### Scripts เสริม

| ไฟล์ | ใช้ทำอะไร |
|---|---|
| `GoldHourlyVolatilityExport.mq5` | รันครั้งเดียวบนกราฟ GOLD เพื่อส่งออกข้อมูลความผันผวนราคาย้อนหลัง แยกตามชั่วโมง |

> ทุก EA เขียน log การเทรดลง `MQL5\Files\<ชื่อไฟล์>_log.csv` อัตโนมัติ — แดชบอร์ดจะดึงไฟล์เหล่านี้มาแสดงผลเอง

---

## การใช้งานแดชบอร์ด

เปิดที่ **http://localhost:8080** หลังรัน `setup.ps1` (หรือ `docker compose up -d` ถ้าตั้งไว้แล้ว)

**ฟีเจอร์หลัก:**
- **ภาพรวม / ผลการเทรด** — win rate, กำไร/ขาดทุนสะสม (equity curve), expectancy ต่อ EA
- **รายการไม้** — ตารางไม้ล่าสุดทุกไม้ พร้อม filter ตาม EA และเลขบัญชี
- **ข่าว** — ข่าวทอง/การเงินแบบเรียลไทม์ (รีเฟรชทุก 5 นาที)
- **ตั้งค่า** — กำหนดทุนเริ่มต้นเพื่อคำนวณ % กำไร/ขาดทุน, อัปโหลด log ด้วยมือ

หน้าเว็บรีเฟรชข้อมูลอัตโนมัติทุก 15 นาที ข้อมูลเก็บใน Postgres ภายใน Docker volume (`dashboard_db-data`)

**คำสั่งจัดการที่ใช้บ่อย** (รันจากโฟลเดอร์ `dashboard`):
```powershell
docker compose up -d         # เปิด
docker compose down          # ปิด
docker compose logs -f server # ดู log สด
docker compose restart server # รีสตาร์ทแค่ตัว API
```

---

## คำแนะนำก่อนใช้งานจริง

1. ทดสอบทุก EA บนบัญชี **Demo** อย่างน้อยหลายวัน/หลายสัปดาห์ก่อน
2. ปรับ `InpMagic` ให้ไม่ซ้ำกันถ้ารันหลาย EA พร้อมกัน (ทุกไฟล์ตั้งไว้ไม่ซ้ำกันแล้วโดย default)
3. ค่า `InpEmergencyStopUsd/Thb`, `InpDailyProfitTarget*`, `InpDailyLossStop*` ในหลายไฟล์เป็น**ค่าประมาณ** ต้องปรับให้ตรงกับทุนจริงของบัญชีเสมอ
4. กลุ่ม **NoSL** ไม่มีการจำกัดขาดทุนจริงจากโบรกเกอร์ — "emergency stop" เป็นแค่โค้ดของ EA เอง ไม่ใช่ SL จริง และอาจพลาดได้ในสถานการณ์ตลาดผันผวนรุนแรง/การเชื่อมต่อขาดหาย
5. ผลการเทรดในอดีต (ทั้งจาก log และจากการวิเคราะห์ในนี้) **ไม่ได้รับประกันผลในอนาคต**
