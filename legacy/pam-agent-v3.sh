#!/bin/bash

# PAM Automation Agent V3 - IP-based CSV approach
# ผู้พัฒนา: ปรับปรุงจาก pam-agent-v2.sh เป็นระบบ IP-based workflow
# วัตถุประสงค์: จัดการ PAM อัตโนมัติแบบใหม่ใช้ไฟล์ user_creds_extracted.csv
#
# คุณสมบัติใหม่ใน V3:
# - ระบบ IP-based workflow แทนการใช้ไฟล์หลายไฟล์
# - ตรวจจับ private IP อัตโนมัติหรือให้ผู้ใช้เลือก
# - ค้นหาผู้ใช้ที่ตรงกับ IP ที่เลือกใน CSV
# - สร้างไฟล์ user_list.csv และ ssh_key_list.csv ที่เข้ากันได้
# - เมนู 5 ตัวเลือก: PAM Creation, SSH Security Hardening, Show PAM Status, Clean-up, CSV Generation
# - ใช้ภาษาไทยสำหรับ UI และ comments
# - รักษาความเข้ากันได้กับตรรกะ pam.example.sh
# - รวม libpwquality installation กับ password policy setup เป็น optional step
# - แยก SSH hardening จาก main PAM creation workflow
#
# รูปแบบไฟล์: user_credentials_extracted.csv (private-ip,username,password,ssh-public-key)

set -euo pipefail

# ตัวแปรส่วนกลาง
USER_CREDS_FILE="user_creds_extracted.csv"
USER_LIST_FILE="user_list.csv"
SSH_KEY_LIST_FILE="ssh_key_list.csv"
BACKUP_DIR=""
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
CURRENT_IP=""

# อาร์เรย์สำหรับติดตาม rollback
declare -a CREATED_USERS=()
declare -a MODIFIED_FILES=()
declare -a CREATED_SSH_DIRS=()
declare -a PROCESSED_USERS=()

# สีสำหรับแสดงผล
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ฟังก์ชัน logging พร้อมเขียนไฟล์
log() {
    local message="$1"
    local color="${2:-$NC}"
    echo -e "${color}${message}${NC}"
}

# การจัดการข้อผิดพลาดพร้อม rollback
error_exit() {
    log "❌ ข้อผิดพลาด: $1" "$RED"
    log "🔄 เริ่มต้น rollback อย่างปลอดภัย..." "$YELLOW"
    safe_rollback
    exit 1
}

# ฟังก์ชัน rollback อย่างปลอดภัย
safe_rollback() {
    log "🔄 กำลังดำเนินการ rollback..." "$YELLOW"

    # คืนค่าไฟล์ที่แก้ไข
    for file in "${MODIFIED_FILES[@]}"; do
        if [[ -f "${file}.backup_${TIMESTAMP}" ]]; then
            sudo cp "${file}.backup_${TIMESTAMP}" "$file"
            log "✅ คืนค่าไฟล์: $file" "$GREEN"
        fi
    done

    # ลบ user ที่สร้างขึ้น
    for user in "${CREATED_USERS[@]}"; do
        if id "$user" &>/dev/null; then
            sudo userdel -r "$user" 2>/dev/null || true
            log "✅ ลบผู้ใช้: $user" "$GREEN"
        fi
    done

    # ลบโฟลเดอร์ .ssh ที่สร้างขึ้น
    for ssh_dir in "${CREATED_SSH_DIRS[@]}"; do
        if [[ -d "$ssh_dir" ]]; then
            sudo rm -rf "$ssh_dir"
            log "✅ ลบโฟลเดอร์: $ssh_dir" "$GREEN"
        fi
    done

    log "🔄 Rollback เสร็จสิ้น" "$YELLOW"
}

# ตรวจสอบการมีอยู่ของไฟล์ที่จำเป็น
check_required_files() {
    if [[ ! -f "$USER_CREDS_FILE" ]]; then
        error_exit "ไม่พบไฟล์ $USER_CREDS_FILE กรุณาตรวจสอบ"
    fi

    # ตรวจสอบรูปแบบไฟล์
    if ! head -1 "$USER_CREDS_FILE" | grep -q "private-ip,username,password,ssh-public-key"; then
        error_exit "รูปแบบไฟล์ $USER_CREDS_FILE ไม่ถูกต้อง"
    fi
}

# ดึงรายการ IP ที่มีในไฟล์
get_available_ips() {
    if [[ ! -f "$USER_CREDS_FILE" ]]; then
        return 1
    fi

    # ข้าม header และดึง IP ที่ไม่ซ้ำ
    tail -n +2 "$USER_CREDS_FILE" | cut -d',' -f1 | sort -u | tr -d '"'
}

# ตรวจจับ private IP ปัจจุบัน
detect_current_ip() {
    # หา private IP ของเครื่องปัจจุบัน
    local detected_ip=""

    # ลองหา IP จาก interface หลัก
    detected_ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo "")

    if [[ -z "$detected_ip" ]]; then
        # ถ้าไม่เจอ ลองใช้ hostname -I
        detected_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")
    fi

    if [[ -z "$detected_ip" ]]; then
        # ถ้ายังไม่เจอ ลองจาก ifconfig
        detected_ip=$(ifconfig 2>/dev/null | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1' | head -1 || echo "")
    fi

    echo "$detected_ip"
}

# ตรวจสอบว่า IP มีในไฟล์หรือไม่
check_ip_in_file() {
    local ip="$1"
    if [[ -z "$ip" ]]; then
        return 1
    fi

    # ตรวจสอบใน CSV โดยคำนึงถึง quotes
    grep -q "^\"*${ip}\"*," "$USER_CREDS_FILE" 2>/dev/null
}

# เลือก IP สำหรับใช้งาน
select_ip() {
    log "🔍 กำลังตรวจหา private IP..." "$CYAN"

    local available_ips
    available_ips=($(get_available_ips))

    if [[ ${#available_ips[@]} -eq 0 ]]; then
        error_exit "ไม่พบ IP ใดๆ ในไฟล์ $USER_CREDS_FILE"
    fi

    # ตรวจจับ IP ปัจจุบัน
    local detected_ip
    detected_ip=$(detect_current_ip)

    log "📋 รายการ IP ที่มีในระบบ:" "$BLUE"
    for i in "${!available_ips[@]}"; do
        local ip="${available_ips[$i]}"
        if [[ "$ip" == "$detected_ip" ]]; then
            log "  $((i + 1))) $ip (ตรวจพบเป็น IP ปัจจุบัน) ⭐" "$GREEN"
        else
            log "  $((i + 1))) $ip" "$YELLOW"
        fi
    done

    # ถ้ามี IP เดียวให้ใช้อัตโนมัติ
    if [[ ${#available_ips[@]} -eq 1 ]]; then
        CURRENT_IP="${available_ips[0]}"
        log "✅ ใช้ IP อัตโนมัติ: $CURRENT_IP" "$GREEN"
        return 0
    fi

    # ถ้าตรวจพบ IP ปัจจุบันในรายการให้เสนอใช้
    if [[ -n "$detected_ip" ]] && check_ip_in_file "$detected_ip"; then
        echo
        read -p "🤔 พบ IP ปัจจุบัน ($detected_ip) ในรายการ ต้องการใช้หรือไม่? (y/n): " use_detected
        if [[ "$use_detected" =~ ^[Yy] ]]; then
            CURRENT_IP="$detected_ip"
            log "✅ ใช้ IP ที่ตรวจพบ: $CURRENT_IP" "$GREEN"
            return 0
        fi
    fi

    # ให้ผู้ใช้เลือก
    echo
    while true; do
        read -p "🎯 กรุณาเลือกหมายเลข IP (1-${#available_ips[@]}) หรือพิมพ์ IP โดยตรง: " choice

        # ตรวจสอบว่าเป็นตัวเลข
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#available_ips[@]} ]]; then
            CURRENT_IP="${available_ips[$((choice - 1))]}"
            log "✅ เลือก IP: $CURRENT_IP" "$GREEN"
            break
        # ตรวจสอบว่าเป็น IP address
        elif [[ "$choice" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            if check_ip_in_file "$choice"; then
                CURRENT_IP="$choice"
                log "✅ ใช้ IP ที่ระบุ: $CURRENT_IP" "$GREEN"
                break
            else
                log "❌ ไม่พบ IP $choice ในไฟล์" "$RED"
            fi
        else
            log "❌ กรุณาใส่หมายเลขที่ถูกต้องหรือ IP address" "$RED"
        fi
    done
}

# สร้างไฟล์ user_list.csv และ ssh_key_list.csv จาก IP ที่เลือก
generate_csv_files() {
    if [[ -z "$CURRENT_IP" ]]; then
        error_exit "ไม่ได้เลือก IP"
    fi

    log "📝 กำลังสร้างไฟล์ CSV จาก IP: $CURRENT_IP..." "$CYAN"

    # สร้างไฟล์ user_list.csv
    echo "username,password" >"$USER_LIST_FILE"

    # สร้างไฟล์ ssh_key_list.csv
    echo "username,ssh_public_key" >"$SSH_KEY_LIST_FILE"

    local user_count=0

    # อ่านไฟล์และกรองตาม IP
    while IFS=',' read -r ip username password ssh_key || [[ -n "$ip" ]]; do
        # ข้าม header
        if [[ "$ip" == "private-ip" ]]; then
            continue
        fi

        # ลบ quotes
        ip=$(echo "$ip" | tr -d '"')
        username=$(echo "$username" | tr -d '"')
        password=$(echo "$password" | tr -d '"')

        if [[ "$ip" == "$CURRENT_IP" ]]; then
            # เพิ่มใน user_list.csv
            echo "\"$username\",\"$password\"" >>"$USER_LIST_FILE"

            # เพิ่มใน ssh_key_list.csv
            echo "\"$username\",$ssh_key" >>"$SSH_KEY_LIST_FILE"

            ((user_count++))
        fi
    done <"$USER_CREDS_FILE"

    if [[ $user_count -eq 0 ]]; then
        error_exit "ไม่พบผู้ใช้สำหรับ IP: $CURRENT_IP"
    fi

    log "✅ สร้างไฟล์เสร็จสิ้น:" "$GREEN"
    log "   - $USER_LIST_FILE ($user_count ผู้ใช้)" "$GREEN"
    log "   - $SSH_KEY_LIST_FILE ($user_count SSH keys)" "$GREEN"
}

# สร้างโฟลเดอร์ backup
create_backup_dir() {
    BACKUP_DIR="backup_${TIMESTAMP}"
    mkdir -p "$BACKUP_DIR"
    log "📁 สร้างโฟลเดอร์ backup: $BACKUP_DIR" "$BLUE"
}

# สำรองไฟล์
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        sudo cp "$file" "${file}.backup_${TIMESTAMP}"
        MODIFIED_FILES+=("$file")
        log "💾 สำรองไฟล์: $file" "$BLUE"
    fi
}

# ตรวจสอบและติดตั้ง group wheel
setup_wheel_group() {
    log "🔧 กำลังตรวจสอบ group 'wheel'..." "$CYAN"

    if ! getent group wheel >/dev/null 2>&1; then
        sudo groupadd wheel
        log "✅ เพิ่ม group 'wheel' เรียบร้อย" "$GREEN"
    else
        log "ℹ️ group 'wheel' มีอยู่แล้ว" "$YELLOW"
    fi

    if sudo grep -q "^%wheel\s\+ALL=(ALL)\s\+ALL" /etc/sudoers; then
        log "ℹ️ สิทธิ์ sudo สำหรับ group 'wheel' มีอยู่แล้ว" "$YELLOW"
    else
        backup_file "/etc/sudoers"
        echo "%wheel  ALL=(ALL)  ALL" | sudo tee -a /etc/sudoers >/dev/null
        log "✅ เพิ่มสิทธิ์ sudo สำหรับ group 'wheel' แล้ว" "$GREEN"
    fi

    log "ℹ️ สมาชิกใน group 'wheel' ปัจจุบัน:" "$BLUE"
    sudo getent group wheel || log "ไม่มีสมาชิก" "$YELLOW"
}

# ติดตั้ง libpwquality และตั้งค่า password policy (optional)
setup_password_policy() {
    echo
    read -p "🔒 ต้องการติดตั้ง libpwquality และตั้งค่าความปลอดภัยรหัสผ่านหรือไม่? (y/n): " install_pwquality

    if [[ "$install_pwquality" =~ ^[Yy] ]]; then
        log "📦 ติดตั้ง libpam-pwquality..." "$CYAN"
        sudo apt-get update -qq
        sudo apt-get install -y libpam-pwquality
        log "✅ ติดตั้ง libpam-pwquality เรียบร้อยแล้ว" "$GREEN"

        log "🔒 ตั้งค่าความปลอดภัยรหัสผ่านใน /etc/security/pwquality.conf..." "$CYAN"
        backup_file "/etc/security/pwquality.conf"

        sudo sed -i.bak -e 's/^# *minlen = .*/minlen = 14/' \
            -e 's/^# *dcredit = .*/dcredit = -1/' \
            -e 's/^# *ucredit = .*/ucredit = -1/' \
            -e 's/^# *lcredit = .*/lcredit = -1/' \
            -e 's/^# *ocredit = .*/ocredit = -1/' \
            -e 's/^# *enforcing = .*/enforcing = 1/' /etc/security/pwquality.conf

        log "✅ ตั้งค่าความปลอดภัยรหัสผ่านเรียบร้อยแล้ว" "$GREEN"
        log "📋 การตั้งค่าที่เปลี่ยนแปลง:" "$BLUE"
        sudo grep -E '^(minlen|dcredit|ucredit|lcredit|ocredit|enforcing) ' /etc/security/pwquality.conf
    else
        log "⏭️ ข้ามการติดตั้ง libpwquality และการตั้งค่า password policy" "$YELLOW"
    fi
}

# สร้างผู้ใช้และเพิ่มเข้า group wheel
create_users() {
    if [[ ! -f "$USER_LIST_FILE" ]]; then
        error_exit "ไม่พบไฟล์ $USER_LIST_FILE"
    fi

    log "👥 กำลังสร้างผู้ใช้..." "$CYAN"

    local created_count=0
    local skipped_count=0

    # อ่านไฟล์ user_list.csv (ข้าม header)
    while IFS=',' read -r username password || [[ -n "$username" ]]; do
        # ข้าม header
        if [[ "$username" == "username" ]]; then
            continue
        fi

        # ลบ quotes
        username=$(echo "$username" | tr -d '"')
        password=$(echo "$password" | tr -d '"')

        if [[ -z "$username" ]]; then
            continue
        fi

        # ตรวจสอบว่าผู้ใช้มีอยู่แล้วหรือไม่
        if id "$username" &>/dev/null; then
            log "⚠️ ผู้ใช้ $username มีอยู่แล้ว - ข้าม" "$YELLOW"
            ((skipped_count++))
            continue
        fi

        # สร้างผู้ใช้
        sudo useradd -m -G wheel "$username"

        # ตั้งรหัสผ่าน
        echo "$username:$password" | sudo chpasswd

        CREATED_USERS+=("$username")
        PROCESSED_USERS+=("$username")

        log "✅ สร้างผู้ใช้: $username" "$GREEN"
        ((created_count++))

    done <"$USER_LIST_FILE"

    log "📊 สร้างผู้ใช้เสร็จสิ้น: $created_count ใหม่, $skipped_count ข้าม" "$BLUE"
}

# ตั้งอายุรหัสผ่าน 90 วัน
set_password_expiry() {
    log "⏱️ กำลังตั้งอายุรหัสผ่าน 90 วัน..." "$CYAN"

    local set_count=0

    for username in "${PROCESSED_USERS[@]}"; do
        sudo chage -M 90 "$username"
        log "✅ ตั้งอายุรหัสผ่าน 90 วัน: $username" "$GREEN"
        ((set_count++))
    done

    log "📊 ตั้งอายุรหัสผ่านเสร็จสิ้น: $set_count ผู้ใช้" "$BLUE"
}

# สร้างโฟลเดอร์ .ssh และเพิ่ม public key
setup_ssh_keys() {
    if [[ ! -f "$SSH_KEY_LIST_FILE" ]]; then
        error_exit "ไม่พบไฟล์ $SSH_KEY_LIST_FILE"
    fi

    log "🔐 กำลังตั้งค่า SSH keys..." "$CYAN"

    local setup_count=0

    # อ่านไฟล์ ssh_key_list.csv (ข้าม header)
    while IFS=',' read -r username ssh_key || [[ -n "$username" ]]; do
        # ข้าม header
        if [[ "$username" == "username" ]]; then
            continue
        fi

        # ลบ quotes จาก username
        username=$(echo "$username" | tr -d '"')

        if [[ -z "$username" ]] || [[ -z "$ssh_key" ]]; then
            continue
        fi

        # ตรวจสอบว่าผู้ใช้มีอยู่หรือไม่
        if ! id "$username" &>/dev/null; then
            log "⚠️ ไม่พบผู้ใช้ $username - ข้าม SSH key setup" "$YELLOW"
            continue
        fi

        local home_dir
        home_dir=$(eval echo "~$username")
        local ssh_dir="$home_dir/.ssh"
        local authorized_keys="$ssh_dir/authorized_keys"

        # สร้างโฟลเดอร์ .ssh
        if [[ ! -d "$ssh_dir" ]]; then
            sudo mkdir -p "$ssh_dir"
            CREATED_SSH_DIRS+=("$ssh_dir")
        fi

        # เขียน SSH key (overwrite แทน append)
        echo "$ssh_key" | sudo tee "$authorized_keys" >/dev/null

        # ตั้งค่าสิทธิ์
        sudo chown -R "$username:$username" "$ssh_dir"
        sudo chmod 700 "$ssh_dir"
        sudo chmod 600 "$authorized_keys"

        log "✅ ตั้งค่า SSH key: $username" "$GREEN"
        ((setup_count++))

    done <"$SSH_KEY_LIST_FILE"

    log "📊 ตั้งค่า SSH keys เสร็จสิ้น: $setup_count ผู้ใช้" "$BLUE"
}

# SSH Security Hardening
ssh_security_hardening() {
    log "🔒 กำลังเพิ่มความปลอดภัย SSH..." "$CYAN"

    local sshd_config="/etc/ssh/sshd_config"
    backup_file "$sshd_config"

    # สร้างการตั้งค่าใหม่
    local temp_config="/tmp/sshd_config_new"

    # คัดลอกไฟล์เดิม
    sudo cp "$sshd_config" "$temp_config"

    # เพิ่มการตั้งค่าความปลอดภัย
    sudo tee -a "$temp_config" >/dev/null <<'EOF'

# Security hardening settings
Protocol 2
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
MaxSessions 3
LoginGraceTime 60
EOF

    # แทนที่ไฟล์เดิม
    sudo mv "$temp_config" "$sshd_config"

    # ทดสอบการตั้งค่า
    if sudo sshd -t; then
        # รีสตาร์ท SSH service
        sudo systemctl restart sshd || sudo service ssh restart
        log "✅ เพิ่มความปลอดภัย SSH เรียบร้อย" "$GREEN"

        log "📋 การตั้งค่าความปลอดภัยที่เพิ่ม:" "$BLUE"
        echo "  - ปิดการ login ด้วย root"
        echo "  - เปิดใช้ Password และ Public Key Authentication"
        echo "  - ตั้งค่า timeout และจำกัดการเชื่อมต่อ"
        echo "  - จำกัดจำนวนครั้งในการ login"
    else
        log "❌ ข้อผิดพลาดในการตั้งค่า SSH" "$RED"
        # คืนค่าไฟล์เดิม
        sudo cp "${sshd_config}.backup_${TIMESTAMP}" "$sshd_config"
        error_exit "ไม่สามารถใช้การตั้งค่า SSH ใหม่ได้"
    fi
}

# แสดงสถานะ PAM
show_pam_status() {
    log "📊 สถานะระบบ PAM ปัจจุบัน" "$CYAN"
    echo

    # ตรวจสอบ group wheel
    log "🔧 Group Wheel:" "$BLUE"
    if getent group wheel >/dev/null 2>&1; then
        local wheel_members
        wheel_members=$(getent group wheel | cut -d: -f4)
        if [[ -n "$wheel_members" ]]; then
            log "  ✅ มีอยู่ - สมาชิก: $wheel_members" "$GREEN"
        else
            log "  ✅ มีอยู่ - ไม่มีสมาชิก" "$YELLOW"
        fi
    else
        log "  ❌ ไม่มี group wheel" "$RED"
    fi

    # ตรวจสอบ sudo permissions
    log "🔑 Sudo Permissions:" "$BLUE"
    if sudo grep -q "^%wheel\s\+ALL=(ALL)\s\+ALL" /etc/sudoers; then
        log "  ✅ group wheel มีสิทธิ์ sudo" "$GREEN"
    else
        log "  ❌ group wheel ไม่มีสิทธิ์ sudo" "$RED"
    fi

    # ตรวจสอบ password policy
    log "🔒 Password Policy:" "$BLUE"
    if [[ -f "/etc/security/pwquality.conf" ]]; then
        if grep -q "^minlen" /etc/security/pwquality.conf; then
            log "  ✅ มีการตั้งค่า password policy" "$GREEN"
            local minlen=$(grep "^minlen" /etc/security/pwquality.conf | cut -d= -f2 | tr -d ' ')
            log "    - ความยาวขั้นต่ำ: $minlen ตัวอักษร" "$BLUE"
        else
            log "  ⚠️ ไม่มีการตั้งค่า password policy" "$YELLOW"
        fi
    else
        log "  ❌ ไม่พบไฟล์ pwquality.conf" "$RED"
    fi

    # ตรวจสอบผู้ใช้ที่มี IP ปัจจุบัน
    if [[ -n "$CURRENT_IP" ]]; then
        log "👥 ผู้ใช้สำหรับ IP $CURRENT_IP:" "$BLUE"
        local user_count=0

        while IFS=',' read -r ip username password ssh_key || [[ -n "$ip" ]]; do
            if [[ "$ip" == "private-ip" ]]; then
                continue
            fi

            ip=$(echo "$ip" | tr -d '"')
            username=$(echo "$username" | tr -d '"')

            if [[ "$ip" == "$CURRENT_IP" ]]; then
                if id "$username" &>/dev/null; then
                    # ตรวจสอบ SSH key
                    local home_dir
                    home_dir=$(eval echo "~$username")
                    local ssh_status="❌"

                    if [[ -f "$home_dir/.ssh/authorized_keys" ]]; then
                        ssh_status="✅"
                    fi

                    # ตรวจสอบอายุรหัสผ่าน
                    local passwd_status
                    passwd_status=$(sudo chage -l "$username" | grep "Password expires" | cut -d: -f2 | tr -d ' ')

                    log "  ✅ $username (SSH: $ssh_status, Password expires: $passwd_status)" "$GREEN"
                else
                    log "  ❌ $username (ไม่มีในระบบ)" "$RED"
                fi
                ((user_count++))
            fi
        done <"$USER_CREDS_FILE"

        log "📊 รวม: $user_count ผู้ใช้" "$BLUE"
    fi

    # ตรวจสอบ SSH configuration
    log "🔐 SSH Configuration:" "$BLUE"
    if [[ -f "/etc/ssh/sshd_config" ]]; then
        local root_login
        root_login=$(grep "^PermitRootLogin" /etc/ssh/sshd_config | awk '{print $2}' || echo "not set")
        log "  - PermitRootLogin: $root_login" "$BLUE"

        local password_auth
        password_auth=$(grep "^PasswordAuthentication" /etc/ssh/sshd_config | awk '{print $2}' || echo "not set")
        log "  - PasswordAuthentication: $password_auth" "$BLUE"

        local pubkey_auth
        pubkey_auth=$(grep "^PubkeyAuthentication" /etc/ssh/sshd_config | awk '{print $2}' || echo "not set")
        log "  - PubkeyAuthentication: $pubkey_auth" "$BLUE"
    fi

    echo
}

# ทำความสะอาดระบบ
cleanup_system() {
    log "🧹 เริ่มต้นทำความสะอาดระบบ..." "$CYAN"

    echo
    read -p "⚠️ คุณแน่ใจหรือไม่ที่จะลบผู้ใช้ทั้งหมดสำหรับ IP $CURRENT_IP? (yes/no): " confirm

    if [[ "$confirm" != "yes" ]]; then
        log "❌ ยกเลิกการทำความสะอาด" "$YELLOW"
        return
    fi

    local cleanup_count=0

    # ลบผู้ใช้ที่เกี่ยวข้องกับ IP ปัจจุบัน
    while IFS=',' read -r ip username password ssh_key || [[ -n "$ip" ]]; do
        if [[ "$ip" == "private-ip" ]]; then
            continue
        fi

        ip=$(echo "$ip" | tr -d '"')
        username=$(echo "$username" | tr -d '"')

        if [[ "$ip" == "$CURRENT_IP" ]] && id "$username" &>/dev/null; then
            sudo userdel -r "$username" 2>/dev/null || true
            log "✅ ลบผู้ใช้: $username" "$GREEN"
            ((cleanup_count++))
        fi
    done <"$USER_CREDS_FILE"

    # ตรวจสอบว่ายังมีสมาชิกใน group wheel หรือไม่
    local wheel_members
    wheel_members=$(getent group wheel | cut -d: -f4)

    if [[ -z "$wheel_members" ]]; then
        read -p "🤔 ไม่มีสมาชิกใน group wheel แล้ว ต้องการลบ group wheel หรือไม่? (y/n): " remove_wheel
        if [[ "$remove_wheel" =~ ^[Yy] ]]; then
            sudo groupdel wheel 2>/dev/null || true
            log "✅ ลบ group wheel" "$GREEN"

            # ลบสิทธิ์ sudo
            if sudo grep -q "^%wheel\s\+ALL=(ALL)\s\+ALL" /etc/sudoers; then
                sudo sed -i.bak '/^%wheel\s\+ALL=(ALL)\s\+ALL/d' /etc/sudoers
                log "✅ ลบสิทธิ์ sudo สำหรับ group wheel" "$GREEN"
            fi
        fi
    fi

    # ลบไฟล์ CSV ที่สร้างขึ้น
    if [[ -f "$USER_LIST_FILE" ]]; then
        rm -f "$USER_LIST_FILE"
        log "✅ ลบไฟล์: $USER_LIST_FILE" "$GREEN"
    fi

    if [[ -f "$SSH_KEY_LIST_FILE" ]]; then
        rm -f "$SSH_KEY_LIST_FILE"
        log "✅ ลบไฟล์: $SSH_KEY_LIST_FILE" "$GREEN"
    fi

    log "📊 ทำความสะอาดเสร็จสิ้น: ลบ $cleanup_count ผู้ใช้" "$BLUE"
}

# กระบวนการ PAM Creation หลัก
pam_creation_workflow() {
    log "🚀 เริ่มต้นกระบวนการสร้าง PAM..." "$CYAN"

    # เลือก IP
    select_ip

    # สร้างไฟล์ CSV
    generate_csv_files

    # สร้างโฟลเดอร์ backup
    create_backup_dir

    # ตั้งค่า group wheel
    setup_wheel_group

    # ติดตั้ง password policy (optional)
    setup_password_policy

    # สร้างผู้ใช้
    create_users

    # ตั้งอายุรหัสผ่าน
    set_password_expiry

    # ตั้งค่า SSH keys
    setup_ssh_keys

    log "🎉 กระบวนการสร้าง PAM เสร็จสิ้น!" "$GREEN"
    echo
    show_pam_status
}

# เมนูหลัก
show_main_menu() {
    echo
    log "=======================================" "$CYAN"
    log "      PAM Automation Agent V3" "$CYAN"
    log "    (IP-based CSV Workflow)" "$CYAN"
    log "=======================================" "$CYAN"
    log "1) 🔧 PAM Creation (สร้างระบบ PAM)" "$BLUE"
    log "2) 🔒 SSH Security Hardening (เพิ่มความปลอดภัย SSH)" "$BLUE"
    log "3) 📊 Show PAM Status (แสดงสถานะ PAM)" "$BLUE"
    log "4) 🧹 Clean-up (ทำความสะอาดระบบ)" "$BLUE"
    log "5) 📝 CSV Generation (สร้างไฟล์ CSV)" "$BLUE"
    log "6) 🚪 Exit (ออก)" "$BLUE"
    log "=======================================" "$CYAN"
}

# ฟังก์ชันหลัก
main() {
    # ตรวจสอบการรัน

    # ตรวจสอบ sudo
    if ! sudo -v; then
        error_exit "ต้องมีสิทธิ์ sudo ในการใช้งาน"
    fi

    # ตรวจสอบไฟล์ที่จำเป็น
    check_required_files

    while true; do
        show_main_menu
        echo
        read -p "🎯 กรุณาเลือกหมายเลข (1-6): " choice

        case $choice in
        1)
            echo
            log "🔧 เริ่มต้น PAM Creation..." "$GREEN"
            pam_creation_workflow
            ;;
        2)
            echo
            log "🔒 เริ่มต้น SSH Security Hardening..." "$GREEN"
            ssh_security_hardening
            ;;
        3)
            echo
            if [[ -z "$CURRENT_IP" ]]; then
                log "⚠️ ยังไม่ได้เลือก IP กรุณาเลือก IP ก่อน" "$YELLOW"
                select_ip
            fi
            show_pam_status
            ;;
        4)
            echo
            if [[ -z "$CURRENT_IP" ]]; then
                log "⚠️ ยังไม่ได้เลือก IP กรุณาเลือก IP ก่อน" "$YELLOW"
                select_ip
            fi
            cleanup_system
            ;;
        5)
            echo
            log "📝 เริ่มต้น CSV Generation..." "$GREEN"
            select_ip
            generate_csv_files
            ;;
        6)
            echo
            log "👋 ขอบคุณที่ใช้งาน PAM Automation Agent V3" "$GREEN"
            exit 0
            ;;
        *)
            log "❌ กรุณาเลือกหมายเลข 1-6" "$RED"
            ;;
        esac

        echo
        read -p "📄 กด Enter เพื่อกลับไปยังเมนูหลัก..."
    done
}

# ดักจับ signals สำหรับ cleanup
trap 'error_exit "สคริปต์ถูกหยุดโดยผู้ใช้"' INT TERM

# เริ่มต้นโปรแกรม
main "$@"
