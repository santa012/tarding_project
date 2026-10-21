"""
เปิดแอพ MetaTrader 5 (mobile) บน LDPlayer emulator แบบอัตโนมัติ ผ่าน ldconsole + adb

วิธีใช้:
    python open_mt5_ldplayer.py

ก่อนใช้ ต้องแก้ค่า config ด้านล่างให้ตรงกับเครื่องตัวเอง:
    - LDPLAYER_PATH : โฟลเดอร์ที่ติดตั้ง LDPlayer (มีไฟล์ ldconsole.exe และ adb.exe)
    - INSTANCE_NAME : ชื่อ instance ใน LDPlayer (ดูได้จาก ldconsole.exe list2)
    - MT5_PACKAGE   : package name ของแอพ MT5 (ปกติคือ net.metaquotes.metatrader5)

หา package name ของแอพที่ติดตั้งแล้วด้วยคำสั่ง:
    adb shell pm list packages | findstr metaquotes
"""

import subprocess
import sys
import time

# ---------- config: แก้ให้ตรงกับเครื่องตัวเอง ----------
LDPLAYER_PATH = r"C:\LDPlayer\LDPlayer14"
INSTANCE_NAME = "LDPlayer"
MT5_PACKAGE = "net.metaquotes.metatrader5"
MT5_ACTIVITY = ".ui.MainActivity"
BOOT_TIMEOUT_SEC = 60
# --------------------------------------------------------

LDCONSOLE = f"{LDPLAYER_PATH}\\ldconsole.exe"
ADB = f"{LDPLAYER_PATH}\\adb.exe"


def run(cmd: list[str]) -> str:
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"[warn] command failed: {' '.join(cmd)}\n{result.stderr}")
    return result.stdout.strip()


def is_running(instance_name: str) -> bool:
    output = run([LDCONSOLE, "isrunning", "--name", instance_name])
    return output.lower() == "running"


def start_instance(instance_name: str) -> None:
    if is_running(instance_name):
        print(f"[info] {instance_name} กำลังรันอยู่แล้ว")
        return
    print(f"[info] กำลังเปิด {instance_name} ...")
    run([LDCONSOLE, "launch", "--name", instance_name])

    waited = 0
    while not is_running(instance_name):
        if waited >= BOOT_TIMEOUT_SEC:
            print("[error] เปิด instance ไม่สำเร็จภายในเวลาที่กำหนด")
            sys.exit(1)
        time.sleep(2)
        waited += 2
    print("[info] instance บูตเสร็จแล้ว")
    # เผื่อเวลาให้ระบบ Android ข้างในพร้อมใช้งานจริง
    time.sleep(5)


def open_mt5_app(package_name: str) -> None:
    print(f"[info] กำลังเปิดแอพ {package_name} ...")
    run([ADB, "shell", "am", "start", "-n", f"{package_name}/{MT5_ACTIVITY}"])
    print("[info] สั่งเปิดแอพเรียบร้อย")


def main() -> None:
    start_instance(INSTANCE_NAME)
    open_mt5_app(MT5_PACKAGE)


if __name__ == "__main__":
    main()
