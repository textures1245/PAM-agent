# PAM Automation Agent V4

**PAM Agent V4** เป็นระบบจัดการ PAM (Pluggable Authentication Modules) อัตโนมัติที่สมบูรณ์ พร้อมด้วยระบบกู้คืน SSH ฉุกเฉิน และการจัดการผู้ใช้งานแบบ JSON-based Smart IP Detection

### 🚀 ความสำเร็จหลัก

- **✅ Complete V4 Implementation**: ระบบ JSON-based workflow ที่สมบูรณ์
- **✅ Emergency SSH Recovery**: ระบบกู้คืน SSH service เมื่อเกิดปัญหา (Option 99)
- **✅ Enhanced Error Handling**: การจัดการ error แบบ graceful แทน strict mode
- **✅ Smart IP Detection**: ระบบตรวจจับ IP อัตโนมัติจาก VM IP ปัจจุบัน
- **✅ Advanced Features**: PAM Advanced Options (P'Aomsin Script)
- **✅ Production Ready**: พร้อมใช้งานจริงด้วยความปลอดภัยสูง

## 📁 โครงสร้างไฟล์

```
pam-automation/
├── extract-clean-users-creds-v3.sh     # สคริปต์แปลง CSV เป็น JSON
├── pam-agent-v4.sh                     # PAM Agent V4 Phase 3 หลัก
├── user_credentials_clean.json         # ไฟล์ JSON ข้อมูลผู้ใช้ (output จาก V3)
├── etc/
│   ├── user_list.csv                   # ไฟล์ CSV ผู้ใช้ (สร้างโดย V4)
│   └── ssh_key_list.csv               # ไฟล์ CSV SSH keys (สร้างโดย V4)
└── raw_user_list_v2.csv           # ไฟล์ CSV ต้นฉบับจาก PAM Checklist
```

---

## 🎮 คู่มือการใช้งาน

### 📋 ขั้นตอนการใช้งาน PAM Automation Agent V4

#### ขั้นตอนที่ 1: เตรียมไฟล์ CSV จาก PAM Checklist

1. **ดาวน์โหลดไฟล์ CSV** จากโปรเจค PAM Checklist:
   - เข้าไปยังแท็บ "User Credentials" หรือแท็บที่มีข้อมูลผู้ใช้
   - ดาวน์โหลดไฟล์ CSV ที่มีรูปแบบดังนี้:

```csv
Username,Password,SSH_Public_Key,Team,Employee_ID,Thai_Name,English_Name,ZONE-1,,,ZONE-2,,,ZONE-3,,,ZONE-4,,,ZONE-5,,,ZONE-6,,,ZONE-7,,,ZONE-8,,,ZONE-9,,,ZONE-10
,,,,,,,VM-WEB-01,VM-WEB-02,VM-WEB-03,VM-APP-01,VM-APP-02,VM-APP-03,VM-DB-01,VM-DB-02,VM-DB-03,VM-LB-01,VM-LB-02,VM-LB-03,VM-CACHE-01,VM-CACHE-02,VM-CACHE-03,VM-QUEUE-01,VM-QUEUE-02,VM-QUEUE-03,VM-MON-01,VM-MON-02,VM-MON-03,VM-LOG-01,VM-LOG-02,VM-LOG-03
,,,,,,,PRIVATE_10.0.1.10,PRIVATE_10.0.1.11,PRIVATE_10.0.1.12,PRIVATE_10.0.2.10,PRIVATE_10.0.2.11,PRIVATE_10.0.2.12,PRIVATE_10.0.3.10,PRIVATE_10.0.3.11,PRIVATE_10.0.3.12,PRIVATE_10.0.4.10,PRIVATE_10.0.4.11,PRIVATE_10.0.4.12,PRIVATE_10.0.5.10,PRIVATE_10.0.5.11,PRIVATE_10.0.5.12,PRIVATE_10.0.6.10,PRIVATE_10.0.6.11,PRIVATE_10.0.6.12,PRIVATE_10.0.7.10,PRIVATE_10.0.7.11,PRIVATE_10.0.7.12,PRIVATE_10.0.8.10,PRIVATE_10.0.8.11,PRIVATE_10.0.8.12
User johndoe,P@ssw0rd123!,ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyData1234567890ABCDEF,DevOps Team,EMP001,จอห์น โด,John Doe,TRUE,TRUE,FALSE,TRUE,FALSE,FALSE,FALSE,FALSE,FALSE,TRUE,TRUE,FALSE,FALSE,FALSE,FALSE,FALSE,FALSE,FALSE,TRUE,FALSE,FALSE,FALSE,FALSE,FALSE
User janesmith,SecureP@ss456,ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDExampleRSAKeyDataHere1234567890...,Security Team,EMP002,เจน สมิธ,Jane Smith,FALSE,FALSE,TRUE,FALSE,TRUE,TRUE,TRUE,TRUE,FALSE,FALSE,FALSE,TRUE,TRUE,TRUE,FALSE,TRUE,TRUE,FALSE,FALSE,TRUE,FALSE,TRUE,FALSE,TRUE
User bobwilson,MyStr0ngP@ss,ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAnotherExampleKeyForBob987654321,Database Team,EMP003,บ็อบ วิลสัน,Bob Wilson,FALSE,FALSE,FALSE,FALSE,FALSE,FALSE,TRUE,TRUE,TRUE,FALSE,FALSE,FALSE,FALSE,FALSE,TRUE,FALSE,FALSE,TRUE,FALSE,FALSE,TRUE,FALSE,TRUE,TRUE
```

2. **ตรวจสอบรูปแบบไฟล์ CSV**:
   - **Header Structure**: ต้องมี 3 แถวแรกเป็น header
     - แถวที่ 1: `Username,Password,SSH_Public_Key,Team,Employee_ID,Thai_Name,English_Name,ZONE-1,,,ZONE-2,...`
     - แถวที่ 2: `,,,,,,VM-NAME-1,VM-NAME-2,VM-NAME-3,...`
     - แถวที่ 3: `,,,,,,PRIVATE_192.168.0.1,PRIVATE_192.168.0.2,...`
   - **User Rows**: แถวข้อมูลผู้ใช้ที่ขึ้นต้นด้วย `"User "`
   - **Boolean Values**: ค่า `TRUE`/`FALSE` สำหรับการกำหนดสิทธิ์ access IP

#### ขั้นตอนที่ 2: แปลงไฟล์ CSV เป็น JSON

1. **วางไฟล์ CSV** ที่ดาวน์โหลดมาใน directory `internal-v2/data/` และตั้งชื่อเป็น `raw_user_list_v2.csv`

2. **รันสคริปต์แปลงข้อมูล**:

```bash
# ให้สิทธิ์การใช้งาน
chmod +x extract-clean-users-creds-v3.sh

# รันสคริปต์แปลงข้อมูล
./extract-clean-users-creds-v3.sh
```

3. **สคริปต์จะทำการ**:
   - ตรวจจับ header structure แบบ dynamic
   - แยกข้อมูล username จาก pattern `"User username"`
   - แปลง boolean logic (TRUE/FALSE) เป็น IP arrays
   - สร้างไฟล์ `user_credentials_clean.json` ที่พร้อมใช้กับ PAM Agent V4

#### ขั้นตอนที่ 3: ใช้งาน PAM Agent V4

1. **เตรียมระบบ**:

```bash
# ตรวจสอบสิทธิ์ sudo
sudo -v

# ให้สิทธิ์การใช้งาน
chmod +x pam-agent-v4.sh

# รันสคริปต์หลัก
sudo ./pam-agent-v4.sh
```

2. **เมนูตัวเลือก**:

```
=======================================
      PAM Automation Agent V4
   (JSON-based Smart IP Detection)
    Phase 3 - Enhanced Features
=======================================
1) 🔧 PAM Creation (สร้างระบบ PAM)
2) 🔒 SSH Security Hardening (เพิ่มความปลอดภัย SSH)
3) 📊 Show PAM Status (แสดงสถานะ PAM)
4) 🧹 Clean-up (ทำความสะอาดระบบ)
5) 📝 CSV Generation (สร้างไฟล์ CSV)
6) 🛠️ PAM Advanced Options (P'Aomsin Script)
7) 🗂️ Advanced Cleanup (ทำความสะอาดขั้นสูง)
8) 🚪 Exit (ออก)

🆘 Emergency Options:
99) 🚨 Emergency SSH System Fix (แก้ไขระบบ SSH ฉุกเฉิน)
=======================================
```

### 📖 คำอธิบายตัวเลือก

#### ตัวเลือกหลัก

**1) PAM Creation (สร้างระบบ PAM)**

- สร้างระบบ PAM อัตโนมัติแบบครบครัน
- ระบบจะตรวจจับ IP ปัจจุบันของ VM และแสดงผู้ใช้ที่เกี่ยวข้อง
- สร้างผู้ใช้, กำหนดรหัสผ่าน, ตั้งค่า SSH keys
- รวมถึงการตั้งค่า wheel group และ sudo permissions

**2) SSH Security Hardening (เพิ่มความปลอดภัย SSH)**

- ปิด PasswordAuthentication (เหลือเฉพาะ key-based)
- ปิด Root login
- ตั้งค่าความปลอดภัย SSH ตาม best practices
- ⚠️ **คำเตือน**: ตรวจสอบ SSH keys ก่อนใช้งาน!

**3) Show PAM Status (แสดงสถานะ PAM)**

- แสดงสถานะผู้ใช้ในระบบ
- ตรวจสอบ SSH keys และการตั้งค่า
- แสดงข้อมูล password expiry
- ตรวจสอบการตั้งค่า SSH configuration

**4) Clean-up (ทำความสะอาดระบบ)**

- ลบผู้ใช้ที่สร้างขึ้น
- ลบ SSH keys และ directories
- คืนค่าการตั้งค่าระบบ
- ตัวเลือกสำหรับทดสอบหรือยกเลิกการติดตั้ง

**5) CSV Generation (สร้างไฟล์ CSV)**

- สร้างไฟล์ CSV จากข้อมูล JSON สำหรับผู้ใช้ที่เลือก
- แสดงตัวเลือก IP addresses ที่ available
- สร้าง `user_list.csv` และ `ssh_key_list.csv`

#### ตัวเลือกขั้นสูง

**6) PAM Advanced Options (P'Aomsin Script)**

- เรียกใช้สคริปต์ `pam.example.sh` จาก GitLab repository
- มี 18 ตัวเลือกสำหรับจัดการ PAM แบบ manual
- เหมาะสำหรับการ fine-tuning หรือ advanced configuration

**7) Advanced Cleanup (ทำความสะอาดขั้นสูง)**

- ลบ backup files ทั้งหมด
- ลบ CSV และ JSON files ที่สร้างขึ้น
- ถอนการติดตั้ง dependencies (jq, libpam-pwquality)
- ทำความสะอาด apt cache

#### ตัวเลือกฉุกเฉิน

**99) Emergency SSH System Fix (แก้ไขระบบ SSH ฉุกเฉิน)**

- ใช้เมื่อ SSH service ไม่สามารถเริ่มได้
- สร้าง `/run/sshd` directory ที่หาย
- สร้าง SSH host keys ใหม่
- คืนค่า SSH configuration เป็นค่า default ที่ทำงานได้
- รีสตาร์ท SSH service อย่างปลอดภัย

### 🔧 ระบบ Smart IP Detection

PAM Agent V4 มีระบบ Smart IP Detection ที่ทำงานดังนี้:

1. **Auto-Detection**: ตรวจจับ IP address ปัจจุบันของ VM
2. **JSON Matching**: หาผู้ใช้ที่มีสิทธิ์ access IP นั้น ๆ
3. **Single Match**: หาก match เพียงรายการเดียว → auto-select
4. **Multiple Matches**: แสดงตัวเลือกให้ผู้ใช้เลือก
5. **No Match**: แจ้งเตือนและให้เลือกจาก IP addresses ทั้งหมด

### 🛡️ ฟีเจอร์ความปลอดภัย

- **Automatic Backup**: สำรองไฟล์ก่อนแก้ไขทุกครั้ง
- **Configuration Testing**: ทดสอบ SSH config ก่อน apply
- **Rollback Mechanism**: คืนค่าการตั้งค่าเดิมเมื่อเกิดข้อผิดพลาด
- **User Confirmation**: ขอยืนยันสำหรับการดำเนินการที่อันตราย
- **Error Handling**: จัดการ error แบบ graceful ไม่ให้ระบบ crash

### ⚠️ ข้อควรระวัง

1. **SSH Keys**: ตรวจสอบ SSH keys ให้ถูกต้องก่อนใช้ SSH Hardening
2. **Backup Access**: เตรียม console access หรือ alternative access method
3. **Password Expiry**: ระบบจะถาม password expiry (default = ไม่หมดอายุ)
4. **Root Access**: หลัง SSH Hardening จะไม่สามารถ login ด้วย root ได้
5. **Emergency Recovery**: ใช้ option 99 เฉพาะเมื่อ SSH service มีปัญหา

### 📝 ไฟล์ Output

หลังการใช้งาน จะได้ไฟล์ดังนี้:

- `user_credentials_clean.json` - ข้อมูล JSON ที่แปลงแล้ว
- `user_list.csv` - รายการผู้ใช้สำหรับ IP ที่เลือก
- `ssh_key_list.csv` - SSH keys สำหรับผู้ใช้
- `backup_*` directories - ไฟล์ backup ต่าง ๆ

---

### รูปแบบข้อมูล CSV Input

```csv
Username,Password,SSH_Public_Key,Team,Employee_ID,Thai_Name,English_Name,ZONE-1,,,ZONE-2,,,ZONE-3,...
,,,,,,,VM-WEB-01,VM-WEB-02,VM-WEB-03,VM-APP-01,VM-APP-02,VM-APP-03,...
,,,,,,,PRIVATE_10.0.1.10,PRIVATE_10.0.1.11,PRIVATE_10.0.1.12,...
User johndoe,P@ssw0rd123!,ssh-ed25519 AAAA...,DevOps Team,EMP001,จอห์น โด,John Doe,TRUE,TRUE,FALSE,TRUE,FALSE,FALSE,FALSE,FALSE,FALSE,TRUE,TRUE,FALSE,FALSE,FALSE,FALSE,FALSE,FALSE,FALSE,TRUE,FALSE,FALSE,FALSE,FALSE,FALSE
User janesmith,SecureP@ss456,ssh-rsa AAAA...,Security Team,EMP002,เจน สมิธ,Jane Smith,FALSE,FALSE,TRUE,FALSE,TRUE,TRUE,TRUE,TRUE,FALSE,FALSE,FALSE,TRUE,TRUE,TRUE,FALSE,TRUE,TRUE,FALSE,FALSE,TRUE,FALSE,TRUE,FALSE,TRUE
```

### รูปแบบข้อมูล JSON Output

**ไฟล์ JSON ที่สร้างขึ้น (`user_credentials_clean.json`)**:

```json
{
  "metadata": {
    "generated_at": "2025-06-14",
    "extraction_method": "Unified CSV Template V3",
    "source_files": ["test_row_dynamic_raw_user_list_v2-2.csv"],
    "format_version": "3.0",
    "column_detection": {
      "username_column": 3,
      "password_column": 5,
      "ssh_key_column": 7,
      "ip_columns": 19,
      "username_detected": true,
      "password_detected": true,
      "ssh_key_detected": true,
      "ip_columns_detected": true
    },
    "row_detection": {
      "pattern": "User ",
      "total_rows": 13,
      "valid_rows": 13
    },
    "description": "Clean user credentials from unified CSV template with IP boolean columns"
  },
  "users": [
    {
      "username": "johndoe",
      "password": "P@ssw0rd123!",
      "ssh_public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyData1234567890ABCDEF",
      "assigned_ips": [
        "10.0.1.10",
        "10.0.1.11",
        "10.0.2.10",
        "10.0.4.10",
        "10.0.4.11",
        "10.0.7.10"
      ],
      "metadata": {
        "created_at": "2025-06-14",
        "last_updated": "2025-06-14",
        "ip_count": 4
      }
    },
    {
      "username": "janesmith",
      "password": "SecureP@ss456",
      "ssh_public_key": "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDExampleRSAKeyDataHere1234567890...",
      "assigned_ips": [
        "10.0.1.12",
        "10.0.2.11",
        "10.0.2.12",
        "10.0.3.10",
        "10.0.3.11",
        "10.0.4.12",
        "10.0.5.10",
        "10.0.5.11",
        "10.0.6.10",
        "10.0.6.11",
        "10.0.7.11",
        "10.0.8.12"
      ],
      "metadata": {
        "created_at": "2025-06-14",
        "last_updated": "2025-06-14",
        "ip_count": 4
      }
    },
    {
      "username": "bobwilson",
      "password": "MyStr0ngP@ss",
      "ssh_public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAnotherExampleKeyForBob987654321",
      "assigned_ips": [
        "10.0.3.10",
        "10.0.3.11",
        "10.0.3.12",
        "10.0.5.12",
        "10.0.6.12",
        "10.0.7.12",
        "10.0.8.11",
        "10.0.8.12"
      ],
      "metadata": {
        "created_at": "2025-06-14",
        "last_updated": "2025-06-14",
        "ip_count": 4
      }
    }
  ],
  "ip_mappings": {
    "10.0.1.10": ["johndoe"],
    "10.0.1.11": ["johndoe"],
    "10.0.1.12": ["janesmith"],
    "10.0.2.10": ["johndoe"],
    "10.0.2.11": ["janesmith"],
    "10.0.2.12": ["janesmith"],
    "10.0.3.10": ["janesmith", "bobwilson"],
    "10.0.3.11": ["janesmith", "bobwilson"],
    "10.0.3.12": ["bobwilson"]
  }
}
```

### Workflow การทำงาน

**PAM Creation Workflow**: `Smart IP Detection → CSV Generation → User Creation → SSH Setup → Security Hardening`

1. **Smart IP Detection**: ตรวจจับ IP ปัจจุบันของ VM
2. **JSON Processing**: หาผู้ใช้ที่มีสิทธิ์ access IP นั้น
3. **CSV Generation**: สร้าง local CSV files สำหรับ PAM workflow
4. **User Management**: สร้าง user accounts และ wheel group
5. **SSH Configuration**: ตั้งค่า SSH keys และ directories
6. **Security Implementation**: ใช้ PAM policies และ SSH hardening

---

## 🚀 คู่มือการติดตั้งและใช้งาน

### ความต้องการของระบบ

- **OS**: Ubuntu/Debian ที่มี `apt-get`
- **Privileges**: สิทธิ์ sudo access
- **Dependencies**: `jq`, `curl`, `systemctl`, `useradd`, `usermod`, `groupadd`
- **Network**: เชื่อมต่อ internet สำหรับดาวน์โหลด dependencies

### วิธีการติดตั้ง

1. **Clone หรือดาวน์โหลดโปรเจค**:

```bash
# ถ้ามี git repository
git clone <repository-url>
cd pam-automation

# หรือคัดลอกไฟล์จาก source
```

2. **ให้สิทธิ์การใช้งาน**:

```bash
chmod +x extract-clean-users-creds-v3.sh
chmod +x pam-agent-v4.sh
chmod +x emergency_ssh_system_fix.sh
```

3. **ตรวจสอบสิทธิ์ sudo**:

```bash
sudo -v
```

### วิธีการใช้งานแบบ Quick Start

```bash
# ขั้นตอนที่ 1: วางไฟล์ CSV ต้นฉบับ
cp your_downloaded_file.csv internal-v2/data/raw_user_list_v2.csv

# ขั้นตอนที่ 2: แปลง CSV เป็น JSON
./extract-clean-users-creds-v3.sh

# ขั้นตอนที่ 3: รัน PAM Agent V4
sudo ./pam-agent-v4.sh
```

### ขั้นตอนการใช้งาน

**สำหรับ Production Environment**:

```bash
# รัน PAM Creation (Option 1)
# ตรวจสอบสถานะด้วย Show Status (Option 3) - Check ว่าสามารถใช้ login ด้วย​ User ที่ถูก registered
# รัน SSH Security Hardening (Option 2) 
# ตรวจสอบสถานะด้วย Show Status (Option 3) - Check ว่าสามารถใช้ login ด้วย​ User ที่ถูก registered และไม่สามารถ Login ด้วย root-user ได้อีกต่อไป
```

**สำหรับการกู้คืนฉุกเฉิน**:

```bash
# ถ้า SSH service ไม่ทำงาน
sudo ./pam-agent-v4.sh
# เลือก Option 99 - Emergency SSH System Fix
```

---

## 🛡️ คุณสมบัติด้านความปลอดภัย

### ระบบ Backup อัตโนมัติ

- **Timestamped Backups**: สร้าง backup directory แบบ `backup_YYYYMMDD_HHMMSS/`
- **File Backup**: สำรองไฟล์ config ทั้งหมดก่อนแก้ไข
- **Rollback Support**: คืนค่าการตั้งค่าเดิมเมื่อเกิดข้อผิดพลาด

### การจัดการ Error

- **Graceful Error Handling**: ระบบไม่ crash เมื่อเจอ error
- **Warning System**: แยกแยะระหว่าง warning และ critical error
- **Continuation Logic**: ทำงานต่อได้แม้เจอปัญหาบางส่วน

### ระบบ Validation

- **Pre-flight Checks**: ตรวจสอบระบบก่อนเริ่มงาน
- **Configuration Testing**: ทดสอบ SSH config ก่อน apply
- **User Confirmation**: ขอยืนยันสำหรับการดำเนินการที่อันตราย

---

## 🔧 การแก้ไขปัญหา

### ปัญหาที่พบบ่อย

**1. SSH Service ไม่สามารถเริ่มได้**

```bash
# อาการ: SSH service failed to start
# สาเหตุ: Missing /run/sshd directory หรือ corrupted config
# วิธีแก้: ใช้ Option 99 - Emergency SSH System Fix
sudo ./pam-agent-v4.sh
# เลือก 99
```

**2. ไฟล์ JSON ไม่ถูกสร้าง**

```bash
# อาการ: extract-clean-users-creds-v3.sh ไม่สร้าง JSON
# สาเหตุ: CSV format ไม่ถูกต้องหรือ missing header
# วิธีแก้: ตรวจสอบ CSV format ให้ตรงตาม specification
```

**3. User ไม่สามารถ login ด้วย SSH key ได้**

```bash
# อาการ: SSH key authentication failed
# สาเหตุ: SSH key format ผิดหรือ permissions ไม่ถูกต้อง
# วิธีแก้: ใช้ Option 3 เพื่อตรวจสอบสถานะ SSH keys
```

**4. Permission Denied เมื่อรันสคริปต์**

```bash
# อาการ: Permission denied
# สาเหตุ: ไฟล์ไม่มีสิทธิ์ execute หรือไม่ได้รันด้วย sudo
# วิธีแก้:
chmod +x *.sh
sudo ./pam-agent-v4.sh
```

### การ Debug

**เปิดใช้งาน Debug Mode**:

```bash
# ถ้าต้องการ debug สคริปต์
bash -x ./pam-agent-v4.sh
```

**ตรวจสอบ Log Files**:

```bash
# ตรวจสอบ SSH service logs
sudo journalctl -xeu ssh.service
sudo journalctl -xeu sshd.service

# ตรวจสอบ system logs
sudo tail -f /var/log/syslog
```

---

## 📚 เอกสารเพิ่มเติม

### เอกสารที่มีอยู่

- **PAM_AGENT_V4_PHASE3_COMPLETE.md** - เอกสารเทคนิคฉบับสมบูรณ์
- **DEPLOYMENT_GUIDE.md** - คู่มือการ deploy สำหรับ production
- **SSH_RECOVERY_DEPLOYMENT.md** - คู่มือการกู้คืน SSH

### Log Files ที่สร้างขึ้น

- สคริปต์จะสร้าง backup directories: `backup_YYYYMMDD_HHMMSS/`
- ไฟล์ JSON output: `user_credentials_clean.json`
- CSV files ที่สร้างขึ้น: `user_list.csv`, `ssh_key_list.csv`

---
