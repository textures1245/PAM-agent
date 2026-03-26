#!/bin/bash

# PAM Automation Agent V4 - JSON-based Smart IP Detection - Phase 3
# Rocky Linux compatibility adjustments (uses yum/dnf, sshd service name, package install helpers)

USER_CREDS_JSON="./user_credentials_clean.json"
USER_LIST_FILE="user_list.csv"
SSH_KEY_LIST_FILE="ssh_key_list.csv"
BACKUP_DIR=""
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
CURRENT_IP=""
PASSWORD_EXPIRY_DAYS=""

declare -a CREATED_USERS=()
declare -a MODIFIED_FILES=()
declare -a CREATED_SSH_DIRS=()
declare -a PROCESSED_USERS=()
declare -a ALL_USERS=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    local message="$1"
    local color="${2:-$NC}"
    echo -e "${color}${message}${NC}"
}

warning_log() {
    log "⚠️  WARNING: $1" "$YELLOW"
}

error_exit() {
    log "❌ ข้อผิดพลาด: $1" "$RED"
    log "🔄 เริ่มต้น rollback อย่างปลอดภัย..." "$YELLOW"
    safe_rollback
    exit 1
}

safe_rollback() {
    log "🔄 กำลังดำเนินการ rollback..." "$YELLOW"

    for file in "${MODIFIED_FILES[@]}"; do
        if [[ -f "${file}.backup_${TIMESTAMP}" ]]; then
            sudo cp "${file}.backup_${TIMESTAMP}" "$file" 2>/dev/null || true
            log "✅ คืนค่าไฟล์: $file" "$GREEN"
        fi
    done

    for user in "${CREATED_USERS[@]}"; do
        if id "$user" &>/dev/null; then
            sudo userdel -r "$user" 2>/dev/null || true
            log "✅ ลบผู้ใช้: $user" "$GREEN"
        fi
    done

    for ssh_dir in "${CREATED_SSH_DIRS[@]}"; do
        if [[ -d "$ssh_dir" ]]; then
            sudo rm -rf "$ssh_dir" 2>/dev/null || true
            log "✅ ลบโฟลเดอร์: $ssh_dir" "$GREEN"
        fi
    done

    log "🔄 Rollback เสร็จสิ้น" "$YELLOW"
}

# Detect package manager (dnf preferred, fallback yum)
detect_pkg_mgr() {
    if command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v yum &>/dev/null; then
        echo "yum"
    else
        echo ""
    fi
}

PKG_MGR=$(detect_pkg_mgr)

install_pkg() {
    local pkg="$1"
    if [[ -z "$PKG_MGR" ]]; then
        warning_log "ไม่พบ package manager ที่รองรับ (dnf/yum)"
        return 1
    fi

    if command -v "$pkg" &>/dev/null; then
        return 0
    fi

    log "📦 ติดตั้ง $pkg ด้วย $PKG_MGR..." "$CYAN"
    if sudo "$PKG_MGR" install -y "$pkg" >/dev/null 2>&1; then
        log "✅ ติดตั้ง $pkg เรียบร้อย" "$GREEN"
        return 0
    else
        warning_log "ไม่สามารถติดตั้ง $pkg โดยอัตโนมัติได้"
        return 1
    fi
}

remove_pkg() {
    local pkg="$1"
    if [[ -z "$PKG_MGR" ]]; then
        warning_log "ไม่พบ package manager ที่รองรับ (dnf/yum)"
        return 1
    fi

    if ! command -v "$pkg" &>/dev/null; then
        log "ℹ️ $pkg ไม่ได้ติดตั้ง" "$YELLOW"
        return 0
    fi

    log "📦 กำลังถอนการติดตั้ง $pkg..." "$CYAN"
    sudo "$PKG_MGR" remove -y "$pkg" >/dev/null 2>&1 || {
        warning_log "ไม่สามารถถอนการติดตั้ง $pkg ได้"
        return 1
    }
    log "✅ ถอนการติดตั้ง $pkg เรียบร้อย" "$GREEN"
    return 0
}

check_required_files() {
    if [[ ! -f "$USER_CREDS_JSON" ]]; then
        error_exit "ไม่พบไฟล์ $USER_CREDS_JSON กรุณาตรวจสอบ"
    fi

    if ! command -v jq &>/dev/null; then
        if ! install_pkg jq; then
            error_exit "jq จำเป็นสำหรับการทำงานของสคริปต์"
        fi
    fi

    if ! jq empty "$USER_CREDS_JSON" 2>/dev/null; then
        error_exit "รูปแบบไฟล์ $USER_CREDS_JSON ไม่ใช่ JSON ที่ถูกต้อง"
    fi

    if ! jq -e '.users and .ip_mappings' "$USER_CREDS_JSON" >/dev/null 2>&1; then
        error_exit "โครงสร้างไฟล์ $USER_CREDS_JSON ไม่ถูกต้อง (ต้องมี users และ ip_mappings)"
    fi
}

get_available_ips() {
    if [[ ! -f "$USER_CREDS_JSON" ]]; then
        return 1
    fi
    jq -r '.ip_mappings | keys[]' "$USER_CREDS_JSON" 2>/dev/null | sort -V
}

detect_current_ip() {
    local detected_ip=""
    detected_ip=$(ip route get 1.1.1.1 2>/dev/null | grep -o 'src [0-9.]*' | awk '{print $2}' || echo "")
    if [[ -z "$detected_ip" ]]; then
        detected_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")
    fi
    if [[ -z "$detected_ip" ]]; then
        detected_ip=$(ifconfig 2>/dev/null | grep -E 'inet [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | grep -v '127.0.0.1' | head -1 | awk '{print $2}' || echo "")
    fi
    echo "$detected_ip"
}

check_ip_in_file() {
    local ip="$1"
    if [[ -z "$ip" ]]; then
        return 1
    fi
    jq -e --arg ip "$ip" '.ip_mappings | has($ip)' "$USER_CREDS_JSON" >/dev/null 2>&1
}

get_password_expiry_days() {
    echo
    log "🔐 การตั้งค่าอายุรหัสผ่าน" "$BLUE"
    log "📝 กรุณาระบุจำนวนวันที่รหัสผ่านจะหมดอายุ" "$CYAN"
    log "   - ใส่จำนวนวันที่ต้องการ (เช่น 90, 180, 365)" "$CYAN"
    log "   - ใส่ 0, ตัวเลขติดลบ หรือกด Enter เพื่อตั้งเป็นไม่หมดอายุ (9999 วัน)" "$CYAN"
    echo

    while true; do
        read -p "🎯 จำนวนวันหมดอายุรหัสผ่าน (กด Enter = ไม่หมดอายุ): " input_days

        if [[ -z "$input_days" ]]; then
            PASSWORD_EXPIRY_DAYS=9999
            log "✅ ตั้งค่ารหัสผ่านเป็นไม่หมดอายุ (9999 วัน)" "$GREEN"
            break
        fi

        if [[ "$input_days" =~ ^-?[0-9]+$ ]]; then
            if [[ "$input_days" -le 0 ]]; then
                PASSWORD_EXPIRY_DAYS=9999
                log "✅ ตั้งค่ารหัสผ่านเป็นไม่หมดอายุ (9999 วัน)" "$GREEN"
                break
            else
                PASSWORD_EXPIRY_DAYS="$input_days"
                log "✅ ตั้งค่ารหัสผ่านหมดอายุใน $PASSWORD_EXPIRY_DAYS วัน" "$GREEN"
                break
            fi
        else
            warning_log "กรุณาใส่ตัวเลขเท่านั้น"
        fi
    done
}

select_ip() {
    log "🔍 กำลังตรวจหา private IP..." "$CYAN"

    local available_ips
    available_ips=($(get_available_ips))

    if [[ ${#available_ips[@]} -eq 0 ]]; then
        error_exit "ไม่พบ IP ใดๆ ในไฟล์ $USER_CREDS_JSON"
    fi

    local detected_ip
    detected_ip=$(detect_current_ip)

    log "📋 รายการ IP ที่มีในระบบ:" "$BLUE"
    for i in "${!available_ips[@]}"; do
        local ip="${available_ips[$i]}"
        local user_count
        user_count=$(jq -r --arg ip "$ip" '.ip_mappings[$ip] | length' "$USER_CREDS_JSON" 2>/dev/null || echo "0")
        if [[ "$ip" == "$detected_ip" ]]; then
            log "  $((i + 1))) $ip (ตรวจพบเป็น IP ปัจจุบัน, $user_count ผู้ใช้) ⭐" "$GREEN"
        else
            log "  $((i + 1))) $ip ($user_count ผู้ใช้)" "$YELLOW"
        fi
    done

    if [[ ${#available_ips[@]} -eq 1 ]]; then
        CURRENT_IP="${available_ips[0]}"
        local user_count
        user_count=$(jq -r --arg ip "$CURRENT_IP" '.ip_mappings[$ip] | length' "$USER_CREDS_JSON" 2>/dev/null || echo "0")
        log "✅ ใช้ IP อัตโนมัติ: $CURRENT_IP ($user_count ผู้ใช้)" "$GREEN"
        return 0
    fi

    if [[ -n "$detected_ip" ]] && check_ip_in_file "$detected_ip"; then
        local user_count
        user_count=$(jq -r --arg ip "$detected_ip" '.ip_mappings[$ip] | length' "$USER_CREDS_JSON" 2>/dev/null || echo "0")
        echo
        read -p "🤔 พบ IP ปัจจุบัน ($detected_ip, $user_count ผู้ใช้) ในรายการ ต้องการใช้หรือไม่? (y/n): " use_detected
        if [[ "$use_detected" =~ ^[Yy] ]]; then
            CURRENT_IP="$detected_ip"
            log "✅ ใช้ IP ที่ตรวจพบ: $CURRENT_IP ($user_count ผู้ใช้)" "$GREEN"
            return 0
        fi
    elif [[ -n "$detected_ip" ]]; then
        log "⚠️ IP ปัจจุบัน ($detected_ip) ไม่มีในข้อมูล JSON" "$YELLOW"
    fi

    echo
    while true; do
        read -p "🎯 กรุณาเลือกหมายเลข IP (1-${#available_ips[@]}) หรือพิมพ์ IP โดยตรง: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#available_ips[@]} ]]; then
            CURRENT_IP="${available_ips[$((choice - 1))]}"
            local user_count
            user_count=$(jq -r --arg ip "$CURRENT_IP" '.ip_mappings[$ip] | length' "$USER_CREDS_JSON" 2>/dev/null || echo "0")
            log "✅ เลือก IP: $CURRENT_IP ($user_count ผู้ใช้)" "$GREEN"
            break
        elif [[ "$choice" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            if check_ip_in_file "$choice"; then
                CURRENT_IP="$choice"
                local user_count
                user_count=$(jq -r --arg ip "$CURRENT_IP" '.ip_mappings[$ip] | length' "$USER_CREDS_JSON" 2>/dev/null || echo "0")
                log "✅ ใช้ IP ที่ระบุ: $CURRENT_IP ($user_count ผู้ใช้)" "$GREEN"
                break
            else
                log "❌ ไม่พบ IP $choice ในไฟล์ JSON" "$RED"
            fi
        else
            log "❌ กรุณาใส่หมายเลขที่ถูกต้องหรือ IP address" "$RED"
        fi
    done
}

generate_csv_files() {
    if [[ -z "$CURRENT_IP" ]]; then
        error_exit "ไม่ได้เลือก IP"
    fi

    log "📝 กำลังสร้างไฟล์ CSV จาก IP: $CURRENT_IP..." "$CYAN"

    local user_count=0
    local usernames
    usernames=($(jq -r --arg ip "$CURRENT_IP" '.ip_mappings[$ip][]?' "$USER_CREDS_JSON" 2>/dev/null))

    if [[ ${#usernames[@]} -eq 0 ]]; then
        error_exit "ไม่พบผู้ใช้สำหรับ IP: $CURRENT_IP"
    fi

    for username in "${usernames[@]}"; do
        local password
        local ssh_key
        password=$(jq -r --arg user "$username" '.users[] | select(.username == $user) | .password // empty' "$USER_CREDS_JSON" 2>/dev/null)
        ssh_key=$(jq -r --arg user "$username" '.users[] | select(.username == $user) | .ssh_public_key // empty' "$USER_CREDS_JSON" 2>/dev/null)

        if [[ -n "$password" ]]; then
            echo "$username","$password" >>"$USER_LIST_FILE"
            echo "$username","$ssh_key" >>"$SSH_KEY_LIST_FILE"
            ((user_count++))
        else
            log "⚠️ ไม่พบข้อมูลสำหรับผู้ใช้: $username" "$YELLOW"
        fi
    done

    if [[ $user_count -eq 0 ]]; then
        error_exit "ไม่สามารถสร้างข้อมูลผู้ใช้สำหรับ IP: $CURRENT_IP"
    fi

    log "✅ สร้างไฟล์เสร็จสิ้น:" "$GREEN"
    log "   - $USER_LIST_FILE ($user_count ผู้ใช้)" "$GREEN"
    log "   - $SSH_KEY_LIST_FILE ($user_count SSH keys)" "$GREEN"
}

create_backup_dir() {
    BACKUP_DIR="backup_${TIMESTAMP}"
    mkdir -p "$BACKUP_DIR"
    log "📁 สร้างโฟลเดอร์ backup: $BACKUP_DIR" "$BLUE"
}

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        sudo cp "$file" "${file}.backup_${TIMESTAMP}" 2>/dev/null || true
        MODIFIED_FILES+=("$file")
        log "💾 สำรองไฟล์: $file" "$BLUE"
    fi
}

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

setup_password_policy() {
    echo
    read -p "🔒 ต้องการติดตั้ง libpwquality และตั้งค่าความปลอดภัยรหัสผ่านหรือไม่? (y/n): " install_pwquality

    if [[ "$install_pwquality" =~ ^[Yy] ]]; then
        # try common package names
        if install_pkg libpwquality || install_pkg libpwquality-libs || install_pkg libpwquality; then
            log "🔒 ตั้งค่าความปลอดภัยรหัสผ่านใน /etc/security/pwquality.conf..." "$CYAN"
            backup_file "/etc/security/pwquality.conf"

            sudo sed -i.bak -e 's/^# *minlen = .*/minlen = 14/' \
                -e 's/^# *dcredit = .*/dcredit = -1/' \
                -e 's/^# *ucredit = .*/ucredit = -1/' \
                -e 's/^# *lcredit = .*/lcredit = -1/' \
                -e 's/^# *ocredit = .*/ocredit = -1/' \
                -e 's/^# *enforcing = .*/enforcing = 1/' /etc/security/pwquality.conf 2>/dev/null || true

            log "✅ ตั้งค่าความปลอดภัยรหัสผ่านเรียบร้อยแล้ว" "$GREEN"
            log "📋 การตั้งค่าที่เปลี่ยนแปลง:" "$BLUE"
            sudo grep -E '^(minlen|dcredit|ucredit|lcredit|ocredit|enforcing) ' /etc/security/pwquality.conf 2>/dev/null || true
        else
            warning_log "ไม่สามารถติดตั้ง libpwquality ได้ ข้ามการตั้งค่า password policy"
            return
        fi
    else
        log "⏭️ ข้ามการติดตั้ง libpwquality และการตั้งค่า password policy" "$YELLOW"
    fi
}

create_users() {
    if [[ ! -f "$USER_LIST_FILE" ]]; then
        error_exit "ไม่พบไฟล์ $USER_LIST_FILE"
    fi

    log "👥 กำลังสร้างผู้ใช้..." "$CYAN"

    local created_count=0
    local skipped_count=0

    while IFS=',' read -r username password || [[ -n "$username" ]]; do
        if [[ "$username" == "username" ]]; then
            continue
        fi

        username=$(echo "$username" | tr -d '"')
        password=$(echo "$password" | tr -d '"')

        if [[ -z "$username" ]]; then
            continue
        fi

        ALL_USERS+=("$username")

        if id "$username" &>/dev/null; then
            log "⚠️ ผู้ใช้ $username มีอยู่แล้ว - ข้าม" "$YELLOW"
            ((skipped_count++))
            continue
        fi

        sudo useradd -m -s /bin/bash -G wheel "$username" || {
            warning_log "ไม่สามารถสร้างผู้ใช้ $username ได้"
            continue
        }

        echo "$username:$password" | sudo chpasswd || {
            warning_log "ไม่สามารถตั้งรหัสผ่านสำหรับ $username ได้"
            sudo userdel -r "$username" 2>/dev/null || true
            continue
        }

        CREATED_USERS+=("$username")
        PROCESSED_USERS+=("$username")

        log "✅ สร้างผู้ใช้: $username" "$GREEN"
        ((created_count++))

    done <"$USER_LIST_FILE"

    log "📊 สร้างผู้ใช้เสร็จสิ้น: $created_count ใหม่, $skipped_count ข้าม" "$BLUE"
}

set_password_expiry() {
    if [[ -z "$PASSWORD_EXPIRY_DAYS" ]]; then
        error_exit "ไม่ได้กำหนดจำนวนวันหมดอายุรหัสผ่าน"
    fi

    log "⏱️ กำลังตั้งอายุรหัสผ่าน $PASSWORD_EXPIRY_DAYS วัน..." "$CYAN"
    log "🔍 Debug: PASSWORD_EXPIRY_DAYS = $PASSWORD_EXPIRY_DAYS" "$BLUE"

    local set_count=0

    if [[ ${#PROCESSED_USERS[@]} -ne ${#ALL_USERS[@]} ]]; then
        read -p "⚠️ ผู้ใช้บางรายถูกข้าม ต้องการตั้งอายุรหัสผ่านสำหรับผู้ใช้ที่มีอยู่แล้วด้วยหรือไม่? (y/n): " set_existing
        if [[ "$set_existing" =~ ^[Yy] ]]; then
            PROCESSED_USERS=("${ALL_USERS[@]}")
            log "🔄 จะตั้งอายุรหัสผ่านสำหรับผู้ใช้ทั้งหมด (${#PROCESSED_USERS[@]} คน)" "$BLUE"
        else
            log "⏭️ ข้ามการตั้งอายุรหัสผ่านสำหรับผู้ใช้ที่มีอยู่แล้ว" "$YELLOW"
        fi
    fi

    for username in "${PROCESSED_USERS[@]}"; do
        log "🔍 Debug: กำลังตั้งค่าสำหรับผู้ใช้ $username ด้วยค่า $PASSWORD_EXPIRY_DAYS วัน" "$BLUE"

        sudo chage -M "$PASSWORD_EXPIRY_DAYS" "$username" || {
            warning_log "ไม่สามารถตั้งอายุรหัสผ่านสำหรับ: $username"
            continue
        }

        local actual_days
        actual_days=$(sudo chage -l "$username" | grep "Maximum number of days" | awk -F: '{print $2}' | tr -d ' ')

        if [[ "$PASSWORD_EXPIRY_DAYS" -eq 9999 ]]; then
            log "✅ ตั้งรหัสผ่านไม่หมดอายุ: $username (ค่าจริง: $actual_days วัน)" "$GREEN"
        else
            log "✅ ตั้งอายุรหัสผ่าน $PASSWORD_EXPIRY_DAYS วัน: $username (ค่าจริง: $actual_days วัน)" "$GREEN"
        fi

        ((set_count++))
    done

    log "📊 ตั้งอายุรหัสผ่านเสร็จสิ้น: $set_count ผู้ใช้" "$BLUE"
}

setup_ssh_keys() {
    if [[ ! -f "$SSH_KEY_LIST_FILE" ]]; then
        error_exit "ไม่พบไฟล์ $SSH_KEY_LIST_FILE"
    fi

    log "🔐 กำลังตั้งค่า SSH keys..." "$CYAN"

    local setup_count=0

    while IFS=',' read -r username ssh_key || [[ -n "$username" ]]; do
        if [[ "$username" == "username" ]]; then
            continue
        fi

        username=$(echo "$username" | tr -d '"')

        if [[ -z "$username" ]] || [[ -z "$ssh_key" ]]; then
            continue
        fi

        if ! id "$username" &>/dev/null; then
            log "⚠️ ไม่พบผู้ใช้ $username - ข้าม SSH key setup" "$YELLOW"
            continue
        fi

        local home_dir
        home_dir=$(eval echo "~$username")
        local ssh_dir="$home_dir/.ssh"
        local authorized_keys="$ssh_dir/authorized_keys"

        if [[ ! -d "$ssh_dir" ]]; then
            sudo mkdir -p "$ssh_dir" || {
                warning_log "ไม่สามารถสร้างโฟลเดอร์ .ssh สำหรับ $username ได้"
                continue
            }
            CREATED_SSH_DIRS+=("$ssh_dir")
        fi

        echo "$ssh_key" | sudo tee "$authorized_keys" >/dev/null 2>&1 || {
            warning_log "ไม่สามารถเขียน SSH key สำหรับ $username ได้"
            continue
        }

        sudo chown -R "$username:$username" "$ssh_dir" || {
            warning_log "ไม่สามารถตั้งค่าเจ้าของไฟล์สำหรับ $username ได้"
        }

        sudo chmod 700 "$ssh_dir" && sudo chmod 600 "$authorized_keys" || {
            warning_log "ไม่สามารถตั้งค่าสิทธิ์ไฟล์สำหรับ $username ได้"
        }

        log "✅ ตั้งค่า SSH key: $username" "$GREEN"
        ((setup_count++))

    done <"$SSH_KEY_LIST_FILE"

    log "📊 ตั้งค่า SSH keys เสร็จสิ้น: $setup_count ผู้ใช้" "$BLUE"
}

ssh_security_hardening() {
    log "🔒 เริ่มต้น SSH Security Hardening..." "$CYAN"
    echo
    log "⚠️ การดำเนินการนี้จะปิด Password Authentication และเปิดเฉพาะ Key Authentication" "$YELLOW"
    echo
    read -p "📋 คุณแน่ใจหรือไม่ที่ต้องการดำเนินการต่อ? (yes/no): " confirm

    if [[ "$confirm" != "yes" ]]; then
        log "❌ ยกเลิกการดำเนินการ" "$YELLOW"
        return 0
    fi

    local sshd_config="/etc/ssh/sshd_config"
    backup_file "$sshd_config"

    log "🔧 กำลังแก้ไขไฟล์ /etc/ssh/sshd_config ..." "$BLUE"

    sudo sed -i.bak -E \
        -e 's/^#?PermitRootLogin.*/PermitRootLogin no/' \
        -e 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' \
        -e 's/^#?PermitEmptyPasswords.*/PermitEmptyPasswords no/' \
        -e 's/^#?X11Forwarding.*/X11Forwarding no/' \
        -e 's/^#?UseDNS.*/UseDNS no/' \
        -e 's/^#?UsePAM.*/UsePAM yes/' \
        /etc/ssh/sshd_config || {
        warning_log "ไม่สามารถแก้ไขไฟล์ sshd_config ได้"
        return 1
    }

    if [[ -d "/etc/ssh/sshd_config.d/" ]]; then
        if sudo grep -q "^PasswordAuthentication" /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
            log "🔧 พบ PasswordAuthentication ใน /etc/ssh/sshd_config.d/ - กำลังแก้ไข..." "$BLUE"
            sudo sed -i -E 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config.d/*.conf || {
                warning_log "ไม่สามารถแก้ไขไฟล์ใน sshd_config.d ได้"
                return 1
            }
        fi
    fi

    if [[ -d "/etc/ssh/ssh_config.d/" ]]; then
        if sudo grep -q "^PasswordAuthentication" /etc/ssh/ssh_config.d/*.conf 2>/dev/null; then
            log "🔧 แก้ไขไฟล์ใน /etc/ssh/ssh_config.d/ เพื่อปิด PasswordAuthentication ..." "$BLUE"
            sudo sed -i -E 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/ssh_config.d/*.conf || {
                warning_log "ไม่สามารถแก้ไขไฟล์ใน ssh_config.d ได้"
                return 1
            }
        fi
    fi

    log "🧪 ทดสอบการตั้งค่า SSH..." "$BLUE"
    if ! sudo sshd -t; then
        warning_log "การตั้งค่า SSH ไม่ถูกต้อง กำลังกู้คืนไฟล์เดิม"
        sudo cp "${sshd_config}.bak" "$sshd_config" 2>/dev/null || true
        return 1
    fi

    sudo mkdir -p /run/sshd || {
        warning_log "ไม่สามารถสร้าง SSH privilege separation directory ได้"
    }

    log "🔄 กำลัง restart sshd ..." "$BLUE"
    if sudo systemctl restart sshd 2>/dev/null; then
        log "✅ ตั้งค่า sshd และ restart สำเร็จ" "$GREEN"
        log "📋 การตั้งค่า SSH ที่มีผล:" "$BLUE"
        sudo grep -E "^(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|UsePAM|X11Forwarding)" /etc/ssh/sshd_config 2>/dev/null || true
        log "⚠️ สำคัญ: Password Authentication ถูกปิดแล้ว! ตรวจสอบให้แน่ใจว่าคุณมี SSH key ที่ถูกต้อง" "$YELLOW"
    else
        warning_log "ไม่สามารถรีสตาร์ท SSHD service ได้"
        return 1
    fi
}

show_pam_status() {
    log "📊 สถานะระบบ PAM ปัจจุบัน" "$CYAN"
    echo

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

    log "🔑 Sudo Permissions:" "$BLUE"
    if sudo grep -q "^%wheel\s\+ALL=(ALL)\s\+ALL" /etc/sudoers 2>/dev/null; then
        log "  ✅ group wheel มีสิทธิ์ sudo" "$GREEN"
    else
        log "  ❌ group wheel ไม่มีสิทธิ์ sudo" "$RED"
    fi

    log "🔒 Password Policy:" "$BLUE"
    if [[ -f "/etc/security/pwquality.conf" ]]; then
        if grep -q "^minlen" /etc/security/pwquality.conf 2>/dev/null; then
            log "  ✅ มีการตั้งค่า password policy" "$GREEN"
            local minlen=$(grep "^minlen" /etc/security/pwquality.conf | cut -d= -f2 | tr -d ' ')
            log "    - ความยาวขั้นต่ำ: $minlen ตัวอักษร" "$BLUE"
        else
            log "  ⚠️ ไม่มีการตั้งค่า password policy" "$YELLOW"
        fi
    else
        log "  ❌ ไม่พบไฟล์ pwquality.conf" "$RED"
    fi

    if [[ -n "$CURRENT_IP" ]]; then
        log "👥 ผู้ใช้สำหรับ IP $CURRENT_IP:" "$BLUE"
        local user_count=0
        local usernames
        usernames=($(jq -r --arg ip "$CURRENT_IP" '.ip_mappings[$ip][]?' "$USER_CREDS_JSON" 2>/dev/null))
        for username in "${usernames[@]}"; do
            if id "$username" &>/dev/null; then
                local home_dir
                home_dir=$(eval echo "~$username")
                local ssh_status="❌"
                if [[ -f "$home_dir/.ssh/authorized_keys" ]]; then
                    ssh_status="✅"
                fi
                local passwd_status
                passwd_status=$(sudo chage -l "$username" | grep "Password expires" | cut -d: -f2 | tr -d ' ' || echo "n/a")
                log "  ✅ $username (SSH: $ssh_status, Password expires: $passwd_status)" "$GREEN"
            else
                log "  ❌ $username (ไม่มีในระบบ)" "$RED"
            fi
            ((user_count++))
        done
        log "📊 รวม: $user_count ผู้ใช้" "$BLUE"
    fi

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

cleanup_system() {
    log "🧹 เริ่มต้นทำความสะอาดระบบ..." "$CYAN"

    echo
    read -p "⚠️ คุณแน่ใจหรือไม่ที่จะลบผู้ใช้ทั้งหมดสำหรับ IP $CURRENT_IP? (yes/no): " confirm

    if [[ "$confirm" != "yes" ]]; then
        log "❌ ยกเลิกการทำความสะอาด" "$YELLOW"
        return
    fi

    local cleanup_count=0
    local usernames
    usernames=($(jq -r --arg ip "$CURRENT_IP" '.ip_mappings[$ip][]?' "$USER_CREDS_JSON" 2>/dev/null))

    for username in "${usernames[@]}"; do
        if id "$username" &>/dev/null; then
            sudo userdel -r "$username" 2>/dev/null || true
            log "✅ ลบผู้ใช้: $username" "$GREEN"
            ((cleanup_count++))
        fi
    done

    local wheel_members
    wheel_members=$(getent group wheel | cut -d: -f4)

    if [[ -z "$wheel_members" ]]; then
        read -p "🤔 ไม่มีสมาชิกใน group wheel แล้ว ต้องการลบ group wheel หรือไม่? (y/n): " remove_wheel
        if [[ "$remove_wheel" =~ ^[Yy] ]]; then
            sudo groupdel wheel 2>/dev/null || true
            log "✅ ลบ group wheel" "$GREEN"
            if sudo grep -q "^%wheel\s\+ALL=(ALL)\s\+ALL" /etc/sudoers 2>/dev/null; then
                sudo sed -i.bak '/^%wheel\s\+ALL=(ALL)\s\+ALL/d' /etc/sudoers 2>/dev/null || true
                log "✅ ลบสิทธิ์ sudo สำหรับ group wheel" "$GREEN"
            fi
        fi
    fi

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

run_pam_example_script() {
    log "🔧 เริ่มต้นรัน PAM Advanced Options (P'Aomsin Script) จาก GitLab..." "$CYAN"
    read -p "🤔 ต้องการรันสคริปต์ PAM Example หรือไม่? (y/n): " confirm_run
    if [[ ! "$confirm_run" =~ ^[Yy] ]]; then
        log "❌ ยกเลิกการรันสคริปต์" "$YELLOW"
        return
    fi

    log "📦 กำลังดาวน์โหลดและรันสคริปต์จาก GitLab..." "$CYAN"
    bash <(curl -kfsSL https://gitlab.com/aomsin3310/script/-/raw/main/pam.sh | tr -d '\r') || {
        warning_log "ไม่สามารถรันสคริปต์ PAM Example ได้"
        return 1
    }

    log "✅ รันสคริปต์ PAM Example เสร็จสิ้น" "$GREEN"
}

advanced_cleanup() {
    log "🧹 เริ่มต้นทำความสะอาดขั้นสูง..." "$CYAN"
    echo
    log "📋 ตัวเลือกการทำความสะอาด:" "$BLUE"
    echo "  1) ลบไฟล์ backup ทั้งหมด"
    echo "  2) ลบไฟล์ CSV และ JSON ที่สร้างขึ้น"
    echo "  3) ถอนการติดตั้ง jq (ถ้าติดตั้งโดยสคริปต์)"
    echo "  4) ทำความสะอาดทั้งหมด (1+2+3)"
    echo "  5) ยกเลิก"
    echo
    read -p "🎯 กรุณาเลือกหมายเลข (1-5): " cleanup_choice
    case $cleanup_choice in
    1) cleanup_backup_files ;;
    2) cleanup_generated_files ;;
    3) cleanup_dependencies ;;
    4)
        cleanup_backup_files
        cleanup_generated_files
        cleanup_dependencies
        ;;
    5)
        log "❌ ยกเลิกการทำความสะอาด" "$YELLOW"
        return
        ;;
    *)
        log "❌ กรุณาเลือกหมายเลข 1-5" "$RED"
        return
        ;;
    esac
    log "✅ การทำความสะอาดขั้นสูงเสร็จสิ้น" "$GREEN"
}

cleanup_backup_files() {
    log "🗂️ กำลังลบไฟล์ backup..." "$CYAN"
    local backup_count=0
    for backup_file in *.backup_* /etc/ssh/sshd_config.backup_* /etc/sudoers.backup_* /etc/security/pwquality.conf.backup_*; do
        if [[ -f "$backup_file" ]]; then
            sudo rm -f "$backup_file" 2>/dev/null || {
                warning_log "ไม่สามารถลบไฟล์ backup: $backup_file"
                continue
            }
            log "✅ ลบไฟล์ backup: $backup_file" "$GREEN"
            ((backup_count++))
        fi
    done
    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
        rm -rf "$BACKUP_DIR" || warning_log "ไม่สามารถลบโฟลเดอร์ backup: $BACKUP_DIR"
        log "✅ ลบโฟลเดอร์ backup: $BACKUP_DIR" "$GREEN"
        ((backup_count++))
    fi
    find . -maxdepth 1 -name "backup_*" -type d 2>/dev/null | while read -r dir; do
        rm -rf "$dir" || warning_log "ไม่สามารถลบโฟลเดอร์: $dir"
        log "✅ ลบโฟลเดอร์ backup: $dir" "$GREEN"
        ((backup_count++))
    done
    log "📊 ลบไฟล์ backup เสร็จสิ้น: $backup_count รายการ" "$BLUE"
}

cleanup_generated_files() {
    log "📝 กำลังลบไฟล์ที่สร้างขึ้น..." "$CYAN"
    local file_count=0
    for file in "$USER_LIST_FILE" "$SSH_KEY_LIST_FILE"; do
        if [[ -f "$file" ]]; then
            rm -f "$file" || {
                warning_log "ไม่สามารถลบไฟล์: $file"
                continue
            }
            log "✅ ลบไฟล์: $file" "$GREEN"
            ((file_count++))
        fi
    done
    for temp_file in /tmp/sshd_config_new /tmp/pam_agent_*; do
        if [[ -f "$temp_file" ]]; then
            sudo rm -f "$temp_file" 2>/dev/null || warning_log "ไม่สามารถลบไฟล์ temporary: $temp_file"
            log "✅ ลบไฟล์ temporary: $temp_file" "$GREEN"
            ((file_count++))
        fi
    done
    log "📊 ลบไฟล์ที่สร้างขึ้นเสร็จสิ้น: $file_count รายการ" "$BLUE"
}

cleanup_dependencies() {
    log "📦 กำลังตรวจสอบ dependencies..." "$CYAN"
    echo
    read -p "⚠️ ต้องการถอนการติดตั้ง jq หรือไม่? (y/n): " remove_jq
    if [[ "$remove_jq" =~ ^[Yy] ]]; then
        remove_pkg jq || warning_log "ไม่สามารถถอนการติดตั้ง jq ได้"
    else
        log "⏭️ ข้ามการถอนการติดตั้ง jq" "$YELLOW"
    fi
    read -p "🧹 ต้องการทำความสะอาด package cache หรือไม่? (y/n): " clean_cache
    if [[ "$clean_cache" =~ ^[Yy] ]]; then
        if [[ -n "$PKG_MGR" ]]; then
            sudo "$PKG_MGR" clean all 2>/dev/null || warning_log "ไม่สามารถทำความสะอาด package cache ได้"
            log "✅ ทำความสะอาด package cache เรียบร้อย" "$GREEN"
        fi
    fi
}

pam_creation_workflow() {
    log "🚀 เริ่มต้นกระบวนการสร้าง PAM..." "$CYAN"
    select_ip
    generate_csv_files
    create_backup_dir
    setup_wheel_group
    setup_password_policy
    get_password_expiry_days
    create_users
    set_password_expiry
    setup_ssh_keys
    log "🎉 กระบวนการสร้าง PAM เสร็จสิ้น!" "$GREEN"
    echo
    show_pam_status
}

show_main_menu() {
    echo
    log "=======================================" "$CYAN"
    log "      PAM Automation Agent V4" "$CYAN"
    log "=======================================" "$CYAN"
    log "1) 🔧 PAM Creation (สร้างระบบ PAM)" "$BLUE"
    log "2) 🔒 SSH Security Hardening (เพิ่มความปลอดภัย SSH)" "$BLUE"
    log "3) 📊 Show PAM Status (แสดงสถานะ PAM)" "$BLUE"
    log "4) 🧹 Clean-up (ทำความสะอาดระบบ)" "$BLUE"
    log "5) 📝 CSV Generation (สร้างไฟล์ CSV)" "$BLUE"
    log "6) 🛠️ PAM Advanced Options (P'Aomsin Script)" "$BLUE"
    log "7) 🗂️ Advanced Cleanup (ทำความสะอาดขั้นสูง)" "$BLUE"
    log "8) 🚪 Exit (ออก)" "$BLUE"
    echo
    log "🆘 Emergency Options:" "$RED"
    log "99) 🚨 Emergency SSH System Fix (แก้ไขระบบ SSH ฉุกเฉิน)" "$RED"
    log "=======================================" "$CYAN"
}

emergency_ssh_system_fix() {
    log "🚨 Emergency SSH System Fix - เริ่มต้น..." "$RED"
    echo
    read -p "📋 คุณแน่ใจหรือไม่ที่ต้องการรัน Emergency SSH Fix? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log "❌ ยกเลิกการดำเนินการ" "$YELLOW"
        return 0
    fi

    log "🔧 Step 1: สร้าง SSH privilege separation directory..." "$CYAN"
    sudo mkdir -p /run/sshd || {
        error_exit "ไม่สามารถสร้าง /run/sshd ได้"
    }
    sudo chown root:root /run/sshd
    sudo chmod 755 /run/sshd
    sudo chmod 755 /run 2>/dev/null || true
    log "✅ สร้าง /run/sshd directory เรียบร้อย" "$GREEN"

    log "🔧 Step 2: สำรองและสร้างการตั้งค่า SSH ใหม่..." "$CYAN"
    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.emergency_$(date +%Y%m%d_%H%M%S) 2>/dev/null || true

    sudo tee /etc/ssh/sshd_config > /dev/null << 'EOF'
# Emergency SSH Configuration - System Recovery
Port 22
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

UsePrivilegeSeparation yes

PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PermitEmptyPasswords no
ChallengeResponseAuthentication no

UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*

ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
MaxSessions 3
LoginGraceTime 60
UseDNS yes

Subsystem sftp /usr/lib/openssh/sftp-server
EOF

    if [[ -d "/etc/ssh/sshd_config.d/" ]]; then
        if sudo grep -q "^PasswordAuthentication" /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
            log "🔧 แก้ไขไฟล์ใน /etc/ssh/sshd_config.d/ เพื่อเปิด PasswordAuthentication ..." "$BLUE"
            sudo sed -i -E 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config.d/*.conf || {
                warning_log "ไม่สามารถแก้ไขไฟล์ใน sshd_config.d ได้"
                return 1
            }
        fi
    fi

    log "🔧 Step 3: ตรวจสอบและสร้าง SSH host keys..." "$CYAN"
    sudo mkdir -p /etc/ssh 2>/dev/null || true

    local need_regenerate=false
    local invalid_keys=()

    for key_type in rsa ecdsa ed25519; do
        local key_file="/etc/ssh/ssh_host_${key_type}_key"
        local pub_file="/etc/ssh/ssh_host_${key_type}_key.pub"
        if [[ ! -f "$key_file" ]] || [[ ! -f "$pub_file" ]]; then
            log "⚠️ ไม่พบ ${key_type} key" "$YELLOW"
            invalid_keys+=("$key_type")
            need_regenerate=true
            continue
        fi
        if [[ ! -s "$key_file" ]] || [[ ! -s "$pub_file" ]]; then
            log "⚠️ ${key_type} key ไฟล์เปล่า (invalid)" "$YELLOW"
            invalid_keys+=("$key_type")
            need_regenerate=true
            continue
        fi
        local key_perms=$(stat -c "%a" "$key_file" 2>/dev/null || stat -f "%OLp" "$key_file" 2>/dev/null)
        local pub_perms=$(stat -c "%a" "$pub_file" 2>/dev/null || stat -f "%OLp" "$pub_file" 2>/dev/null)
        if [[ "$key_perms" != "600" ]]; then
            sudo chmod 600 "$key_file" 2>/dev/null || true
        fi
        if [[ "$pub_perms" != "644" ]]; then
            sudo chmod 644 "$pub_file" 2>/dev/null || true
        fi
        if ! ssh-keygen -l -f "$key_file" &>/dev/null; then
            log "⚠️ ${key_type} key ไม่ถูกต้อง (corrupted)" "$YELLOW"
            invalid_keys+=("$key_type")
            need_regenerate=true
            continue
        fi
        log "✅ ${key_type} key ถูกต้อง" "$GREEN"
    done

    if [[ "$need_regenerate" == true ]]; then
        log "🔑 พบ keys ที่ไม่ถูกต้อง: ${invalid_keys[*]}" "$YELLOW"
        for key_type in rsa ecdsa ed25519; do
            if [[ -f "/etc/ssh/ssh_host_${key_type}_key" ]]; then
                sudo cp "/etc/ssh/ssh_host_${key_type}_key" "/etc/ssh/ssh_host_${key_type}_key.emergency_backup_${TIMESTAMP}" 2>/dev/null || true
            fi
        done
        sudo ssh-keygen -A 2>/dev/null || true
        log "✅ SSH host keys สร้างเรียบร้อย" "$GREEN"
    else
        log "✅ SSH host keys ทั้งหมดถูกต้อง - ไม่ต้อง regenerate" "$GREEN"
    fi

    log "🔧 Step 4: ตั้งค่าสิทธิ์ไฟล์..." "$CYAN"
    sudo chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null || true
    sudo chmod 644 /etc/ssh/ssh_host_*_key.pub 2>/dev/null || true
    sudo chmod 644 /etc/ssh/sshd_config 2>/dev/null || true
    sudo chown root:root /etc/ssh/sshd_config 2>/dev/null || true
    sudo chown root:root /etc/ssh/ssh_host_* 2>/dev/null || true
    log "✅ ตั้งค่าสิทธิ์ไฟล์เรียบร้อย" "$GREEN"

    log "🧪 Step 5: ทดสอบการตั้งค่า SSH..." "$CYAN"
    if sudo sshd -t; then
        log "✅ การตั้งค่า SSH ถูกต้อง" "$GREEN"
    else
        error_exit "การตั้งค่า SSH ไม่ถูกต้อง"
    fi

    log "🔄 Step 6: รีสตาร์ท SSH service..." "$CYAN"
    local service_restarted=false
    if sudo systemctl restart sshd 2>/dev/null; then
        service_name="sshd"
        service_restarted=true
    elif sudo service sshd restart 2>/dev/null; then
        service_name="sshd"
        service_restarted=true
    fi

    if [[ "$service_restarted" == "true" ]]; then
        log "✅ SSH service ($service_name) รีสตาร์ทเรียบร้อย" "$GREEN"
    else
        warning_log "ไม่สามารถรีสตาร์ท SSH service ได้"
        return 1
    fi

    log "🔍 Step 7: ตรวจสอบสถานะ service..." "$CYAN"
    sleep 3
    if systemctl is-active --quiet sshd 2>/dev/null || pgrep sshd >/dev/null; then
        log "🎉 SSH service กำลังทำงานปกติ!" "$GREEN"
        log "📋 การตั้งค่า SSH ปัจจุบัน:" "$BLUE"
        echo "----------------------------------------"
        sudo grep -E "^(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|UsePAM|X11Forwarding)" /etc/ssh/sshd_config 2>/dev/null || echo "ไม่สามารถอ่านการตั้งค่า SSH ได้"
        echo "----------------------------------------"
        log "✅ Emergency SSH Recovery เสร็จสิ้น!" "$GREEN"
        log "🔒 Root login ถูกเปิดใช้งาน" "$BLUE"
        log "🔑 Password และ key authentication เปิดใช้งาน" "$BLUE"
        log "⚠️ ตรวจสอบให้แน่ใจว่าสามารถ login ด้วย root user และ non-root user ได้!" "$YELLOW"
    else
        error_exit "SSH service ยังไม่ทำงาน"
    fi
}

main() {
    if [[ $EUID -eq 0 ]]; then
        warning_log "กำลังรันด้วยสิทธิ์ root ซึ่งอาจเป็นอันตราย"
    fi

    if ! sudo -v 2>/dev/null; then
        error_exit "ต้องมีสิทธิ์ sudo ในการใช้งาน"
    fi

    if ! check_required_files; then
        error_exit "ไม่สามารถตรวจสอบไฟล์ที่จำเป็นได้"
    fi

    while true; do
        show_main_menu
        echo
        read -p "🎯 กรุณาเลือกหมายเลข (1-8, 99=ฉุกเฉิน): " choice

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
            log "🛠️ เริ่มต้น PAM Advanced Options (P'Aomsin Script)..." "$GREEN"
            run_pam_example_script
            ;;
        7)
            echo
            log "🗂️ เริ่มต้น Advanced Cleanup..." "$GREEN"
            advanced_cleanup
            ;;
        8)
            echo
            log "👋 ขอบคุณที่ใช้งาน PAM Automation Agent V4 - Phase 3" "$GREEN"
            exit 0
            ;;
        99)
            echo
            log "🚨 เริ่มต้น Emergency SSH System Fix..." "$RED"
            emergency_ssh_system_fix
            ;;
        *)
            log "❌ กรุณาเลือกหมายเลข 1-8 หรือ 99 สำหรับฉุกเฉิน" "$RED"
            ;;
        esac

        echo
        read -p "📄 กด Enter เพื่อกลับไปยังเมนูหลัก..."
    done
}

trap 'error_exit "สคริปต์ถูกหยุดโดยผู้ใช้"' INT TERM

main "$@"
```// filepath: /Users/phakh/multipass-devops-shared/workspace/pam-automation/pam-agent-rocky7-linux.sh
#!/bin/bash

# PAM Automation Agent V4 - JSON-based Smart IP Detection - Phase 3
# Rocky Linux compatibility adjustments (uses yum/dnf, sshd service name, package install helpers)

USER_CREDS_JSON="./user_credentials_clean.json"
USER_LIST_FILE="user_list.csv"
SSH_KEY_LIST_FILE="ssh_key_list.csv"
BACKUP_DIR=""
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
CURRENT_IP=""
PASSWORD_EXPIRY_DAYS=""

declare -a CREATED_USERS=()
declare -a MODIFIED_FILES=()
declare -a CREATED_SSH_DIRS=()
declare -a PROCESSED_USERS=()
declare -a ALL_USERS=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    local message="$1"
    local color="${2:-$NC}"
    echo -e "${color}${message}${NC}"
}

warning_log() {
    log "⚠️  WARNING: $1" "$YELLOW"
}

error_exit() {
    log "❌ ข้อผิดพลาด: $1" "$RED"
    log "🔄 เริ่มต้น rollback อย่างปลอดภัย..." "$YELLOW"
    safe_rollback
    exit 1
}

safe_rollback() {
    log "🔄 กำลังดำเนินการ rollback..." "$YELLOW"

    for file in "${MODIFIED_FILES[@]}"; do
        if [[ -f "${file}.backup_${TIMESTAMP}" ]]; then
            sudo cp "${file}.backup_${TIMESTAMP}" "$file" 2>/dev/null || true
            log "✅ คืนค่าไฟล์: $file" "$GREEN"
        fi
    done

    for user in "${CREATED_USERS[@]}"; do
        if id "$user" &>/dev/null; then
            sudo userdel -r "$user" 2>/dev/null || true
            log "✅ ลบผู้ใช้: $user" "$GREEN"
        fi
    done

    for ssh_dir in "${CREATED_SSH_DIRS[@]}"; do
        if [[ -d "$ssh_dir" ]]; then
            sudo rm -rf "$ssh_dir" 2>/dev/null || true
            log "✅ ลบโฟลเดอร์: $ssh_dir" "$GREEN"
        fi
    done

    log "🔄 Rollback เสร็จสิ้น" "$YELLOW"
}

# Detect package manager (dnf preferred, fallback yum)
detect_pkg_mgr() {
    if command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v yum &>/dev/null; then
        echo "yum"
    else
        echo ""
    fi
}

PKG_MGR=$(detect_pkg_mgr)

install_pkg() {
    local pkg="$1"
    if [[ -z "$PKG_MGR" ]]; then
        warning_log "ไม่พบ package manager ที่รองรับ (dnf/yum)"
        return 1
    fi

    if command -v "$pkg" &>/dev/null; then
        return 0
    fi

    log "📦 ติดตั้ง $pkg ด้วย $PKG_MGR..." "$CYAN"
    if sudo "$PKG_MGR" install -y "$pkg" >/dev/null 2>&1; then
        log "✅ ติดตั้ง $pkg เรียบร้อย" "$GREEN"
        return 0
    else
        warning_log "ไม่สามารถติดตั้ง $pkg โดยอัตโนมัติได้"
        return 1
    fi
}

remove_pkg() {
    local pkg="$1"
    if [[ -z "$PKG_MGR" ]]; then
        warning_log "ไม่พบ package manager ที่รองรับ (dnf/yum)"
        return 1
    fi

    if ! command -v "$pkg" &>/dev/null; then
        log "ℹ️ $pkg ไม่ได้ติดตั้ง" "$YELLOW"
        return 0
    fi

    log "📦 กำลังถอนการติดตั้ง $pkg..." "$CYAN"
    sudo "$PKG_MGR" remove -y "$pkg" >/dev/null 2>&1 || {
        warning_log "ไม่สามารถถอนการติดตั้ง $pkg ได้"
        return 1
    }
    log "✅ ถอนการติดตั้ง $pkg เรียบร้อย" "$GREEN"
    return 0
}

check_required_files() {
    if [[ ! -f "$USER_CREDS_JSON" ]]; then
        error_exit "ไม่พบไฟล์ $USER_CREDS_JSON กรุณาตรวจสอบ"
    fi

    if ! command -v jq &>/dev/null; then
        if ! install_pkg jq; then
            error_exit "jq จำเป็นสำหรับการทำงานของสคริปต์"
        fi
    fi

    if ! jq empty "$USER_CREDS_JSON" 2>/dev/null; then
        error_exit "รูปแบบไฟล์ $USER_CREDS_JSON ไม่ใช่ JSON ที่ถูกต้อง"
    fi

    if ! jq -e '.users and .ip_mappings' "$USER_CREDS_JSON" >/dev/null 2>&1; then
        error_exit "โครงสร้างไฟล์ $USER_CREDS_JSON ไม่ถูกต้อง (ต้องมี users และ ip_mappings)"
    fi
}

get_available_ips() {
    if [[ ! -f "$USER_CREDS_JSON" ]]; then
        return 1
    fi
    jq -r '.ip_mappings | keys[]' "$USER_CREDS_JSON" 2>/dev/null | sort -V
}

detect_current_ip() {
    local detected_ip=""
    detected_ip=$(ip route get 1.1.1.1 2>/dev/null | grep -o 'src [0-9.]*' | awk '{print $2}' || echo "")
    if [[ -z "$detected_ip" ]]; then
        detected_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")
    fi
    if [[ -z "$detected_ip" ]]; then
        detected_ip=$(ifconfig 2>/dev/null | grep -E 'inet [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | grep -v '127.0.0.1' | head -1 | awk '{print $2}' || echo "")
    fi
    echo "$detected_ip"
}

check_ip_in_file() {
    local ip="$1"
    if [[ -z "$ip" ]]; then
        return 1
    fi
    jq -e --arg ip "$ip" '.ip_mappings | has($ip)' "$USER_CREDS_JSON" >/dev/null 2>&1
}

get_password_expiry_days() {
    echo
    log "🔐 การตั้งค่าอายุรหัสผ่าน" "$BLUE"
    log "📝 กรุณาระบุจำนวนวันที่รหัสผ่านจะหมดอายุ" "$CYAN"
    log "   - ใส่จำนวนวันที่ต้องการ (เช่น 90, 180, 365)" "$CYAN"
    log "   - ใส่ 0, ตัวเลขติดลบ หรือกด Enter เพื่อตั้งเป็นไม่หมดอายุ (9999 วัน)" "$CYAN"
    echo

    while true; do
        read -p "🎯 จำนวนวันหมดอายุรหัสผ่าน (กด Enter = ไม่หมดอายุ): " input_days

        if [[ -z "$input_days" ]]; then
            PASSWORD_EXPIRY_DAYS=9999
            log "✅ ตั้งค่ารหัสผ่านเป็นไม่หมดอายุ (9999 วัน)" "$GREEN"
            break
        fi

        if [[ "$input_days" =~ ^-?[0-9]+$ ]]; then
            if [[ "$input_days" -le 0 ]]; then
                PASSWORD_EXPIRY_DAYS=9999
                log "✅ ตั้งค่ารหัสผ่านเป็นไม่หมดอายุ (9999 วัน)" "$GREEN"
                break
            else
                PASSWORD_EXPIRY_DAYS="$input_days"
                log "✅ ตั้งค่ารหัสผ่านหมดอายุใน $PASSWORD_EXPIRY_DAYS วัน" "$GREEN"
                break
            fi
        else
            warning_log "กรุณาใส่ตัวเลขเท่านั้น"
        fi
    done
}

select_ip() {
    log "🔍 กำลังตรวจหา private IP..." "$CYAN"

    local available_ips
    available_ips=($(get_available_ips))

    if [[ ${#available_ips[@]} -eq 0 ]]; then
        error_exit "ไม่พบ IP ใดๆ ในไฟล์ $USER_CREDS_JSON"
    fi

    local detected_ip
    detected_ip=$(detect_current_ip)

    log "📋 รายการ IP ที่มีในระบบ:" "$BLUE"
    for i in "${!available_ips[@]}"; do
        local ip="${available_ips[$i]}"
        local user_count
        user_count=$(jq -r --arg ip "$ip" '.ip_mappings[$ip] | length' "$USER_CREDS_JSON" 2>/dev/null || echo "0")
        if [[ "$ip" == "$detected_ip" ]]; then
            log "  $((i + 1))) $ip (ตรวจพบเป็น IP ปัจจุบัน, $user_count ผู้ใช้) ⭐" "$GREEN"
        else
            log "  $((i + 1))) $ip ($user_count ผู้ใช้)" "$YELLOW"
        fi
    done

    if [[ ${#available_ips[@]} -eq 1 ]]; then
        CURRENT_IP="${available_ips[0]}"
        local user_count
        user_count=$(jq -r --arg ip "$CURRENT_IP" '.ip_mappings[$ip] | length' "$USER_CREDS_JSON" 2>/dev/null || echo "0")
        log "✅ ใช้ IP อัตโนมัติ: $CURRENT_IP ($user_count ผู้ใช้)" "$GREEN"
        return 0
    fi

    if [[ -n "$detected_ip" ]] && check_ip_in_file "$detected_ip"; then
        local user_count
        user_count=$(jq -r --arg ip "$detected_ip" '.ip_mappings[$ip] | length' "$USER_CREDS_JSON" 2>/dev/null || echo "0")
        echo
        read -p "🤔 พบ IP ปัจจุบัน ($detected_ip, $user_count ผู้ใช้) ในรายการ ต้องการใช้หรือไม่? (y/n): " use_detected
        if [[ "$use_detected" =~ ^[Yy] ]]; then
            CURRENT_IP="$detected_ip"
            log "✅ ใช้ IP ที่ตรวจพบ: $CURRENT_IP ($user_count ผู้ใช้)" "$GREEN"
            return 0
        fi
    elif [[ -n "$detected_ip" ]]; then
        log "⚠️ IP ปัจจุบัน ($detected_ip) ไม่มีในข้อมูล JSON" "$YELLOW"
    fi

    echo
    while true; do
        read -p "🎯 กรุณาเลือกหมายเลข IP (1-${#available_ips[@]}) หรือพิมพ์ IP โดยตรง: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#available_ips[@]} ]]; then
            CURRENT_IP="${available_ips[$((choice - 1))]}"
            local user_count
            user_count=$(jq -r --arg ip "$CURRENT_IP" '.ip_mappings[$ip] | length' "$USER_CREDS_JSON" 2>/dev/null || echo "0")
            log "✅ เลือก IP: $CURRENT_IP ($user_count ผู้ใช้)" "$GREEN"
            break
        elif [[ "$choice" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            if check_ip_in_file "$choice"; then
                CURRENT_IP="$choice"
                local user_count
                user_count=$(jq -r --arg ip "$CURRENT_IP" '.ip_mappings[$ip] | length' "$USER_CREDS_JSON" 2>/dev/null || echo "0")
                log "✅ ใช้ IP ที่ระบุ: $CURRENT_IP ($user_count ผู้ใช้)" "$GREEN"
                break
            else
                log "❌ ไม่พบ IP $choice ในไฟล์ JSON" "$RED"
            fi
        else
            log "❌ กรุณาใส่หมายเลขที่ถูกต้องหรือ IP address" "$RED"
        fi
    done
}

generate_csv_files() {
    if [[ -z "$CURRENT_IP" ]]; then
        error_exit "ไม่ได้เลือก IP"
    fi

    log "📝 กำลังสร้างไฟล์ CSV จาก IP: $CURRENT_IP..." "$CYAN"

    local user_count=0
    local usernames
    usernames=($(jq -r --arg ip "$CURRENT_IP" '.ip_mappings[$ip][]?' "$USER_CREDS_JSON" 2>/dev/null))

    if [[ ${#usernames[@]} -eq 0 ]]; then
        error_exit "ไม่พบผู้ใช้สำหรับ IP: $CURRENT_IP"
    fi

    for username in "${usernames[@]}"; do
        local password
        local ssh_key
        password=$(jq -r --arg user "$username" '.users[] | select(.username == $user) | .password // empty' "$USER_CREDS_JSON" 2>/dev/null)
        ssh_key=$(jq -r --arg user "$username" '.users[] | select(.username == $user) | .ssh_public_key // empty' "$USER_CREDS_JSON" 2>/dev/null)

        if [[ -n "$password" ]]; then
            echo "$username","$password" >>"$USER_LIST_FILE"
            echo "$username","$ssh_key" >>"$SSH_KEY_LIST_FILE"
            ((user_count++))
        else
            log "⚠️ ไม่พบข้อมูลสำหรับผู้ใช้: $username" "$YELLOW"
        fi
    done

    if [[ $user_count -eq 0 ]]; then
        error_exit "ไม่สามารถสร้างข้อมูลผู้ใช้สำหรับ IP: $CURRENT_IP"
    fi

    log "✅ สร้างไฟล์เสร็จสิ้น:" "$GREEN"
    log "   - $USER_LIST_FILE ($user_count ผู้ใช้)" "$GREEN"
    log "   - $SSH_KEY_LIST_FILE ($user_count SSH keys)" "$GREEN"
}

create_backup_dir() {
    BACKUP_DIR="backup_${TIMESTAMP}"
    mkdir -p "$BACKUP_DIR"
    log "📁 สร้างโฟลเดอร์ backup: $BACKUP_DIR" "$BLUE"
}

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        sudo cp "$file" "${file}.backup_${TIMESTAMP}" 2>/dev/null || true
        MODIFIED_FILES+=("$file")
        log "💾 สำรองไฟล์: $file" "$BLUE"
    fi
}

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

setup_password_policy() {
    echo
    read -p "🔒 ต้องการติดตั้ง libpwquality และตั้งค่าความปลอดภัยรหัสผ่านหรือไม่? (y/n): " install_pwquality

    if [[ "$install_pwquality" =~ ^[Yy] ]]; then
        # try common package names
        if install_pkg libpwquality || install_pkg libpwquality-libs || install_pkg libpwquality; then
            log "🔒 ตั้งค่าความปลอดภัยรหัสผ่านใน /etc/security/pwquality.conf..." "$CYAN"
            backup_file "/etc/security/pwquality.conf"

            sudo sed -i.bak -e 's/^# *minlen = .*/minlen = 14/' \
                -e 's/^# *dcredit = .*/dcredit = -1/' \
                -e 's/^# *ucredit = .*/ucredit = -1/' \
                -e 's/^# *lcredit = .*/lcredit = -1/' \
                -e 's/^# *ocredit = .*/ocredit = -1/' \
                -e 's/^# *enforcing = .*/enforcing = 1/' /etc/security/pwquality.conf 2>/dev/null || true

            log "✅ ตั้งค่าความปลอดภัยรหัสผ่านเรียบร้อยแล้ว" "$GREEN"
            log "📋 การตั้งค่าที่เปลี่ยนแปลง:" "$BLUE"
            sudo grep -E '^(minlen|dcredit|ucredit|lcredit|ocredit|enforcing) ' /etc/security/pwquality.conf 2>/dev/null || true
        else
            warning_log "ไม่สามารถติดตั้ง libpwquality ได้ ข้ามการตั้งค่า password policy"
            return
        fi
    else
        log "⏭️ ข้ามการติดตั้ง libpwquality และการตั้งค่า password policy" "$YELLOW"
    fi
}

create_users() {
    if [[ ! -f "$USER_LIST_FILE" ]]; then
        error_exit "ไม่พบไฟล์ $USER_LIST_FILE"
    fi

    log "👥 กำลังสร้างผู้ใช้..." "$CYAN"

    local created_count=0
    local skipped_count=0

    while IFS=',' read -r username password || [[ -n "$username" ]]; do
        if [[ "$username" == "username" ]]; then
            continue
        fi

        username=$(echo "$username" | tr -d '"')
        password=$(echo "$password" | tr -d '"')

        if [[ -z "$username" ]]; then
            continue
        fi

        ALL_USERS+=("$username")

        if id "$username" &>/dev/null; then
            log "⚠️ ผู้ใช้ $username มีอยู่แล้ว - ข้าม" "$YELLOW"
            ((skipped_count++))
            continue
        fi

        sudo useradd -m -s /bin/bash -G wheel "$username" || {
            warning_log "ไม่สามารถสร้างผู้ใช้ $username ได้"
            continue
        }

        echo "$username:$password" | sudo chpasswd || {
            warning_log "ไม่สามารถตั้งรหัสผ่านสำหรับ $username ได้"
            sudo userdel -r "$username" 2>/dev/null || true
            continue
        }

        CREATED_USERS+=("$username")
        PROCESSED_USERS+=("$username")

        log "✅ สร้างผู้ใช้: $username" "$GREEN"
        ((created_count++))

    done <"$USER_LIST_FILE"

    log "📊 สร้างผู้ใช้เสร็จสิ้น: $created_count ใหม่, $skipped_count ข้าม" "$BLUE"
}

set_password_expiry() {
    if [[ -z "$PASSWORD_EXPIRY_DAYS" ]]; then
        error_exit "ไม่ได้กำหนดจำนวนวันหมดอายุรหัสผ่าน"
    fi

    log "⏱️ กำลังตั้งอายุรหัสผ่าน $PASSWORD_EXPIRY_DAYS วัน..." "$CYAN"
    log "🔍 Debug: PASSWORD_EXPIRY_DAYS = $PASSWORD_EXPIRY_DAYS" "$BLUE"

    local set_count=0

    if [[ ${#PROCESSED_USERS[@]} -ne ${#ALL_USERS[@]} ]]; then
        read -p "⚠️ ผู้ใช้บางรายถูกข้าม ต้องการตั้งอายุรหัสผ่านสำหรับผู้ใช้ที่มีอยู่แล้วด้วยหรือไม่? (y/n): " set_existing
        if [[ "$set_existing" =~ ^[Yy] ]]; then
            PROCESSED_USERS=("${ALL_USERS[@]}")
            log "🔄 จะตั้งอายุรหัสผ่านสำหรับผู้ใช้ทั้งหมด (${#PROCESSED_USERS[@]} คน)" "$BLUE"
        else
            log "⏭️ ข้ามการตั้งอายุรหัสผ่านสำหรับผู้ใช้ที่มีอยู่แล้ว" "$YELLOW"
        fi
    fi

    for username in "${PROCESSED_USERS[@]}"; do
        log "🔍 Debug: กำลังตั้งค่าสำหรับผู้ใช้ $username ด้วยค่า $PASSWORD_EXPIRY_DAYS วัน" "$BLUE"

        sudo chage -M "$PASSWORD_EXPIRY_DAYS" "$username" || {
            warning_log "ไม่สามารถตั้งอายุรหัสผ่านสำหรับ: $username"
            continue
        }

        local actual_days
        actual_days=$(sudo chage -l "$username" | grep "Maximum number of days" | awk -F: '{print $2}' | tr -d ' ')

        if [[ "$PASSWORD_EXPIRY_DAYS" -eq 9999 ]]; then
            log "✅ ตั้งรหัสผ่านไม่หมดอายุ: $username (ค่าจริง: $actual_days วัน)" "$GREEN"
        else
            log "✅ ตั้งอายุรหัสผ่าน $PASSWORD_EXPIRY_DAYS วัน: $username (ค่าจริง: $actual_days วัน)" "$GREEN"
        fi

        ((set_count++))
    done

    log "📊 ตั้งอายุรหัสผ่านเสร็จสิ้น: $set_count ผู้ใช้" "$BLUE"
}

setup_ssh_keys() {
    if [[ ! -f "$SSH_KEY_LIST_FILE" ]]; then
        error_exit "ไม่พบไฟล์ $SSH_KEY_LIST_FILE"
    fi

    log "🔐 กำลังตั้งค่า SSH keys..." "$CYAN"

    local setup_count=0

    while IFS=',' read -r username ssh_key || [[ -n "$username" ]]; do
        if [[ "$username" == "username" ]]; then
            continue
        fi

        username=$(echo "$username" | tr -d '"')

        if [[ -z "$username" ]] || [[ -z "$ssh_key" ]]; then
            continue
        fi

        if ! id "$username" &>/dev/null; then
            log "⚠️ ไม่พบผู้ใช้ $username - ข้าม SSH key setup" "$YELLOW"
            continue
        fi

        local home_dir
        home_dir=$(eval echo "~$username")
        local ssh_dir="$home_dir/.ssh"
        local authorized_keys="$ssh_dir/authorized_keys"

        if [[ ! -d "$ssh_dir" ]]; then
            sudo mkdir -p "$ssh_dir" || {
                warning_log "ไม่สามารถสร้างโฟลเดอร์ .ssh สำหรับ $username ได้"
                continue
            }
            CREATED_SSH_DIRS+=("$ssh_dir")
        fi

        echo "$ssh_key" | sudo tee "$authorized_keys" >/dev/null 2>&1 || {
            warning_log "ไม่สามารถเขียน SSH key สำหรับ $username ได้"
            continue
        }

        sudo chown -R "$username:$username" "$ssh_dir" || {
            warning_log "ไม่สามารถตั้งค่าเจ้าของไฟล์สำหรับ $username ได้"
        }

        sudo chmod 700 "$ssh_dir" && sudo chmod 600 "$authorized_keys" || {
            warning_log "ไม่สามารถตั้งค่าสิทธิ์ไฟล์สำหรับ $username ได้"
        }

        log "✅ ตั้งค่า SSH key: $username" "$GREEN"
        ((setup_count++))

    done <"$SSH_KEY_LIST_FILE"

    log "📊 ตั้งค่า SSH keys เสร็จสิ้น: $setup_count ผู้ใช้" "$BLUE"
}

ssh_security_hardening() {
    log "🔒 เริ่มต้น SSH Security Hardening..." "$CYAN"
    echo
    log "⚠️ การดำเนินการนี้จะปิด Password Authentication และเปิดเฉพาะ Key Authentication" "$YELLOW"
    echo
    read -p "📋 คุณแน่ใจหรือไม่ที่ต้องการดำเนินการต่อ? (yes/no): " confirm

    if [[ "$confirm" != "yes" ]]; then
        log "❌ ยกเลิกการดำเนินการ" "$YELLOW"
        return 0
    fi

    local sshd_config="/etc/ssh/sshd_config"
    backup_file "$sshd_config"

    log "🔧 กำลังแก้ไขไฟล์ /etc/ssh/sshd_config ..." "$BLUE"

    sudo sed -i.bak -E \
        -e 's/^#?PermitRootLogin.*/PermitRootLogin no/' \
        -e 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' \
        -e 's/^#?PermitEmptyPasswords.*/PermitEmptyPasswords no/' \
        -e 's/^#?X11Forwarding.*/X11Forwarding no/' \
        -e 's/^#?UseDNS.*/UseDNS no/' \
        -e 's/^#?UsePAM.*/UsePAM yes/' \
        /etc/ssh/sshd_config || {
        warning_log "ไม่สามารถแก้ไขไฟล์ sshd_config ได้"
        return 1
    }

    if [[ -d "/etc/ssh/sshd_config.d/" ]]; then
        if sudo grep -q "^PasswordAuthentication" /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
            log "🔧 พบ PasswordAuthentication ใน /etc/ssh/sshd_config.d/ - กำลังแก้ไข..." "$BLUE"
            sudo sed -i -E 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config.d/*.conf || {
                warning_log "ไม่สามารถแก้ไขไฟล์ใน sshd_config.d ได้"
                return 1
            }
        fi
    fi

    if [[ -d "/etc/ssh/ssh_config.d/" ]]; then
        if sudo grep -q "^PasswordAuthentication" /etc/ssh/ssh_config.d/*.conf 2>/dev/null; then
            log "🔧 แก้ไขไฟล์ใน /etc/ssh/ssh_config.d/ เพื่อปิด PasswordAuthentication ..." "$BLUE"
            sudo sed -i -E 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/ssh_config.d/*.conf || {
                warning_log "ไม่สามารถแก้ไขไฟล์ใน ssh_config.d ได้"
                return 1
            }
        fi
    fi

    log "🧪 ทดสอบการตั้งค่า SSH..." "$BLUE"
    if ! sudo sshd -t; then
        warning_log "การตั้งค่า SSH ไม่ถูกต้อง กำลังกู้คืนไฟล์เดิม"
        sudo cp "${sshd_config}.bak" "$sshd_config" 2>/dev/null || true
        return 1
    fi

    sudo mkdir -p /run/sshd || {
        warning_log "ไม่สามารถสร้าง SSH privilege separation directory ได้"
    }

    log "🔄 กำลัง restart sshd ..." "$BLUE"
    if sudo systemctl restart sshd 2>/dev/null; then
        log "✅ ตั้งค่า sshd และ restart สำเร็จ" "$GREEN"
        log "📋 การตั้งค่า SSH ที่มีผล:" "$BLUE"
        sudo grep -E "^(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|UsePAM|X11Forwarding)" /etc/ssh/sshd_config 2>/dev/null || true
        log "⚠️ สำคัญ: Password Authentication ถูกปิดแล้ว! ตรวจสอบให้แน่ใจว่าคุณมี SSH key ที่ถูกต้อง" "$YELLOW"
    else
        warning_log "ไม่สามารถรีสตาร์ท SSHD service ได้"
        return 1
    fi
}

show_pam_status() {
    log "📊 สถานะระบบ PAM ปัจจุบัน" "$CYAN"
    echo

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

    log "🔑 Sudo Permissions:" "$BLUE"
    if sudo grep -q "^%wheel\s\+ALL=(ALL)\s\+ALL" /etc/sudoers 2>/dev/null; then
        log "  ✅ group wheel มีสิทธิ์ sudo" "$GREEN"
    else
        log "  ❌ group wheel ไม่มีสิทธิ์ sudo" "$RED"
    fi

    log "🔒 Password Policy:" "$BLUE"
    if [[ -f "/etc/security/pwquality.conf" ]]; then
        if grep -q "^minlen" /etc/security/pwquality.conf 2>/dev/null; then
            log "  ✅ มีการตั้งค่า password policy" "$GREEN"
            local minlen=$(grep "^minlen" /etc/security/pwquality.conf | cut -d= -f2 | tr -d ' ')
            log "    - ความยาวขั้นต่ำ: $minlen ตัวอักษร" "$BLUE"
        else
            log "  ⚠️ ไม่มีการตั้งค่า password policy" "$YELLOW"
        fi
    else
        log "  ❌ ไม่พบไฟล์ pwquality.conf" "$RED"
    fi

    if [[ -n "$CURRENT_IP" ]]; then
        log "👥 ผู้ใช้สำหรับ IP $CURRENT_IP:" "$BLUE"
        local user_count=0
        local usernames
        usernames=($(jq -r --arg ip "$CURRENT_IP" '.ip_mappings[$ip][]?' "$USER_CREDS_JSON" 2>/dev/null))
        for username in "${usernames[@]}"; do
            if id "$username" &>/dev/null; then
                local home_dir
                home_dir=$(eval echo "~$username")
                local ssh_status="❌"
                if [[ -f "$home_dir/.ssh/authorized_keys" ]]; then
                    ssh_status="✅"
                fi
                local passwd_status
                passwd_status=$(sudo chage -l "$username" | grep "Password expires" | cut -d: -f2 | tr -d ' ' || echo "n/a")
                log "  ✅ $username (SSH: $ssh_status, Password expires: $passwd_status)" "$GREEN"
            else
                log "  ❌ $username (ไม่มีในระบบ)" "$RED"
            fi
            ((user_count++))
        done
        log "📊 รวม: $user_count ผู้ใช้" "$BLUE"
    fi

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

cleanup_system() {
    log "🧹 เริ่มต้นทำความสะอาดระบบ..." "$CYAN"

    echo
    read -p "⚠️ คุณแน่ใจหรือไม่ที่จะลบผู้ใช้ทั้งหมดสำหรับ IP $CURRENT_IP? (yes/no): " confirm

    if [[ "$confirm" != "yes" ]]; then
        log "❌ ยกเลิกการทำความสะอาด" "$YELLOW"
        return
    fi

    local cleanup_count=0
    local usernames
    usernames=($(jq -r --arg ip "$CURRENT_IP" '.ip_mappings[$ip][]?' "$USER_CREDS_JSON" 2>/dev/null))

    for username in "${usernames[@]}"; do
        if id "$username" &>/dev/null; then
            sudo userdel -r "$username" 2>/dev/null || true
            log "✅ ลบผู้ใช้: $username" "$GREEN"
            ((cleanup_count++))
        fi
    done

    local wheel_members
    wheel_members=$(getent group wheel | cut -d: -f4)

    if [[ -z "$wheel_members" ]]; then
        read -p "🤔 ไม่มีสมาชิกใน group wheel แล้ว ต้องการลบ group wheel หรือไม่? (y/n): " remove_wheel
        if [[ "$remove_wheel" =~ ^[Yy] ]]; then
            sudo groupdel wheel 2>/dev/null || true
            log "✅ ลบ group wheel" "$GREEN"
            if sudo grep -q "^%wheel\s\+ALL=(ALL)\s\+ALL" /etc/sudoers 2>/dev/null; then
                sudo sed -i.bak '/^%wheel\s\+ALL=(ALL)\s\+ALL/d' /etc/sudoers 2>/dev/null || true
                log "✅ ลบสิทธิ์ sudo สำหรับ group wheel" "$GREEN"
            fi
        fi
    fi

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

run_pam_example_script() {
    log "🔧 เริ่มต้นรัน PAM Advanced Options (P'Aomsin Script) จาก GitLab..." "$CYAN"
    read -p "🤔 ต้องการรันสคริปต์ PAM Example หรือไม่? (y/n): " confirm_run
    if [[ ! "$confirm_run" =~ ^[Yy] ]]; then
        log "❌ ยกเลิกการรันสคริปต์" "$YELLOW"
        return
    fi

    log "📦 กำลังดาวน์โหลดและรันสคริปต์จาก GitLab..." "$CYAN"
    bash <(curl -kfsSL https://gitlab.com/aomsin3310/script/-/raw/main/pam.sh | tr -d '\r') || {
        warning_log "ไม่สามารถรันสคริปต์ PAM Example ได้"
        return 1
    }

    log "✅ รันสคริปต์ PAM Example เสร็จสิ้น" "$GREEN"
}

advanced_cleanup() {
    log "🧹 เริ่มต้นทำความสะอาดขั้นสูง..." "$CYAN"
    echo
    log "📋 ตัวเลือกการทำความสะอาด:" "$BLUE"
    echo "  1) ลบไฟล์ backup ทั้งหมด"
    echo "  2) ลบไฟล์ CSV และ JSON ที่สร้างขึ้น"
    echo "  3) ถอนการติดตั้ง jq (ถ้าติดตั้งโดยสคริปต์)"
    echo "  4) ทำความสะอาดทั้งหมด (1+2+3)"
    echo "  5) ยกเลิก"
    echo
    read -p "🎯 กรุณาเลือกหมายเลข (1-5): " cleanup_choice
    case $cleanup_choice in
    1) cleanup_backup_files ;;
    2) cleanup_generated_files ;;
    3) cleanup_dependencies ;;
    4)
        cleanup_backup_files
        cleanup_generated_files
        cleanup_dependencies
        ;;
    5)
        log "❌ ยกเลิกการทำความสะอาด" "$YELLOW"
        return
        ;;
    *)
        log "❌ กรุณาเลือกหมายเลข 1-5" "$RED"
        return
        ;;
    esac
    log "✅ การทำความสะอาดขั้นสูงเสร็จสิ้น" "$GREEN"
}

cleanup_backup_files() {
    log "🗂️ กำลังลบไฟล์ backup..." "$CYAN"
    local backup_count=0
    for backup_file in *.backup_* /etc/ssh/sshd_config.backup_* /etc/sudoers.backup_* /etc/security/pwquality.conf.backup_*; do
        if [[ -f "$backup_file" ]]; then
            sudo rm -f "$backup_file" 2>/dev/null || {
                warning_log "ไม่สามารถลบไฟล์ backup: $backup_file"
                continue
            }
            log "✅ ลบไฟล์ backup: $backup_file" "$GREEN"
            ((backup_count++))
        fi
    done
    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
        rm -rf "$BACKUP_DIR" || warning_log "ไม่สามารถลบโฟลเดอร์ backup: $BACKUP_DIR"
        log "✅ ลบโฟลเดอร์ backup: $BACKUP_DIR" "$GREEN"
        ((backup_count++))
    fi
    find . -maxdepth 1 -name "backup_*" -type d 2>/dev/null | while read -r dir; do
        rm -rf "$dir" || warning_log "ไม่สามารถลบโฟลเดอร์: $dir"
        log "✅ ลบโฟลเดอร์ backup: $dir" "$GREEN"
        ((backup_count++))
    done
    log "📊 ลบไฟล์ backup เสร็จสิ้น: $backup_count รายการ" "$BLUE"
}

cleanup_generated_files() {
    log "📝 กำลังลบไฟล์ที่สร้างขึ้น..." "$CYAN"
    local file_count=0
    for file in "$USER_LIST_FILE" "$SSH_KEY_LIST_FILE"; do
        if [[ -f "$file" ]]; then
            rm -f "$file" || {
                warning_log "ไม่สามารถลบไฟล์: $file"
                continue
            }
            log "✅ ลบไฟล์: $file" "$GREEN"
            ((file_count++))
        fi
    done
    for temp_file in /tmp/sshd_config_new /tmp/pam_agent_*; do
        if [[ -f "$temp_file" ]]; then
            sudo rm -f "$temp_file" 2>/dev/null || warning_log "ไม่สามารถลบไฟล์ temporary: $temp_file"
            log "✅ ลบไฟล์ temporary: $temp_file" "$GREEN"
            ((file_count++))
        fi
    done
    log "📊 ลบไฟล์ที่สร้างขึ้นเสร็จสิ้น: $file_count รายการ" "$BLUE"
}

cleanup_dependencies() {
    log "📦 กำลังตรวจสอบ dependencies..." "$CYAN"
    echo
    read -p "⚠️ ต้องการถอนการติดตั้ง jq หรือไม่? (y/n): " remove_jq
    if [[ "$remove_jq" =~ ^[Yy] ]]; then
        remove_pkg jq || warning_log "ไม่สามารถถอนการติดตั้ง jq ได้"
    else
        log "⏭️ ข้ามการถอนการติดตั้ง jq" "$YELLOW"
    fi
    read -p "🧹 ต้องการทำความสะอาด package cache หรือไม่? (y/n): " clean_cache
    if [[ "$clean_cache" =~ ^[Yy] ]]; then
        if [[ -n "$PKG_MGR" ]]; then
            sudo "$PKG_MGR" clean all 2>/dev/null || warning_log "ไม่สามารถทำความสะอาด package cache ได้"
            log "✅ ทำความสะอาด package cache เรียบร้อย" "$GREEN"
        fi
    fi
}

pam_creation_workflow() {
    log "🚀 เริ่มต้นกระบวนการสร้าง PAM..." "$CYAN"
    select_ip
    generate_csv_files
    create_backup_dir
    setup_wheel_group
    setup_password_policy
    get_password_expiry_days
    create_users
    set_password_expiry
    setup_ssh_keys
    log "🎉 กระบวนการสร้าง PAM เสร็จสิ้น!" "$GREEN"
    echo
    show_pam_status
}

show_main_menu() {
    echo
    log "=======================================" "$CYAN"
    log "      PAM Automation Agent V4" "$CYAN"
    log "=======================================" "$CYAN"
    log "1) 🔧 PAM Creation (สร้างระบบ PAM)" "$BLUE"
    log "2) 🔒 SSH Security Hardening (เพิ่มความปลอดภัย SSH)" "$BLUE"
    log "3) 📊 Show PAM Status (แสดงสถานะ PAM)" "$BLUE"
    log "4) 🧹 Clean-up (ทำความสะอาดระบบ)" "$BLUE"
    log "5) 📝 CSV Generation (สร้างไฟล์ CSV)" "$BLUE"
    log "6) 🛠️ PAM Advanced Options (P'Aomsin Script)" "$BLUE"
    log "7) 🗂️ Advanced Cleanup (ทำความสะอาดขั้นสูง)" "$BLUE"
    log "8) 🚪 Exit (ออก)" "$BLUE"
    echo
    log "🆘 Emergency Options:" "$RED"
    log "99) 🚨 Emergency SSH System Fix (แก้ไขระบบ SSH ฉุกเฉิน)" "$RED"
    log "=======================================" "$CYAN"
}

emergency_ssh_system_fix() {
    log "🚨 Emergency SSH System Fix - เริ่มต้น..." "$RED"
    echo
    read -p "📋 คุณแน่ใจหรือไม่ที่ต้องการรัน Emergency SSH Fix? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log "❌ ยกเลิกการดำเนินการ" "$YELLOW"
        return 0
    fi

    log "🔧 Step 1: สร้าง SSH privilege separation directory..." "$CYAN"
    sudo mkdir -p /run/sshd || {
        error_exit "ไม่สามารถสร้าง /run/sshd ได้"
    }
    sudo chown root:root /run/sshd
    sudo chmod 755 /run/sshd
    sudo chmod 755 /run 2>/dev/null || true
    log "✅ สร้าง /run/sshd directory เรียบร้อย" "$GREEN"

    log "🔧 Step 2: สำรองและสร้างการตั้งค่า SSH ใหม่..." "$CYAN"
    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.emergency_$(date +%Y%m%d_%H%M%S) 2>/dev/null || true

    sudo tee /etc/ssh/sshd_config > /dev/null << 'EOF'
# Emergency SSH Configuration - System Recovery
Port 22
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

UsePrivilegeSeparation yes

PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PermitEmptyPasswords no
ChallengeResponseAuthentication no

UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*

ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
MaxSessions 3
LoginGraceTime 60
UseDNS yes

Subsystem sftp /usr/lib/openssh/sftp-server
EOF

    if [[ -d "/etc/ssh/sshd_config.d/" ]]; then
        if sudo grep -q "^PasswordAuthentication" /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
            log "🔧 แก้ไขไฟล์ใน /etc/ssh/sshd_config.d/ เพื่อเปิด PasswordAuthentication ..." "$BLUE"
            sudo sed -i -E 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config.d/*.conf || {
                warning_log "ไม่สามารถแก้ไขไฟล์ใน sshd_config.d ได้"
                return 1
            }
        fi
    fi

    log "🔧 Step 3: ตรวจสอบและสร้าง SSH host keys..." "$CYAN"
    sudo mkdir -p /etc/ssh 2>/dev/null || true

    local need_regenerate=false
    local invalid_keys=()

    for key_type in rsa ecdsa ed25519; do
        local key_file="/etc/ssh/ssh_host_${key_type}_key"
        local pub_file="/etc/ssh/ssh_host_${key_type}_key.pub"
        if [[ ! -f "$key_file" ]] || [[ ! -f "$pub_file" ]]; then
            log "⚠️ ไม่พบ ${key_type} key" "$YELLOW"
            invalid_keys+=("$key_type")
            need_regenerate=true
            continue
        fi
        if [[ ! -s "$key_file" ]] || [[ ! -s "$pub_file" ]]; then
            log "⚠️ ${key_type} key ไฟล์เปล่า (invalid)" "$YELLOW"
            invalid_keys+=("$key_type")
            need_regenerate=true
            continue
        fi
        local key_perms=$(stat -c "%a" "$key_file" 2>/dev/null || stat -f "%OLp" "$key_file" 2>/dev/null)
        local pub_perms=$(stat -c "%a" "$pub_file" 2>/dev/null || stat -f "%OLp" "$pub_file" 2>/dev/null)
        if [[ "$key_perms" != "600" ]]; then
            sudo chmod 600 "$key_file" 2>/dev/null || true
        fi
        if [[ "$pub_perms" != "644" ]]; then
            sudo chmod 644 "$pub_file" 2>/dev/null || true
        fi
        if ! ssh-keygen -l -f "$key_file" &>/dev/null; then
            log "⚠️ ${key_type} key ไม่ถูกต้อง (corrupted)" "$YELLOW"
            invalid_keys+=("$key_type")
            need_regenerate=true
            continue
        fi
        log "✅ ${key_type} key ถูกต้อง" "$GREEN"
    done

    if [[ "$need_regenerate" == true ]]; then
        log "🔑 พบ keys ที่ไม่ถูกต้อง: ${invalid_keys[*]}" "$YELLOW"
        for key_type in rsa ecdsa ed25519; do
            if [[ -f "/etc/ssh/ssh_host_${key_type}_key" ]]; then
                sudo cp "/etc/ssh/ssh_host_${key_type}_key" "/etc/ssh/ssh_host_${key_type}_key.emergency_backup_${TIMESTAMP}" 2>/dev/null || true
            fi
        done
        sudo ssh-keygen -A 2>/dev/null || true
        log "✅ SSH host keys สร้างเรียบร้อย" "$GREEN"
    else
        log "✅ SSH host keys ทั้งหมดถูกต้อง - ไม่ต้อง regenerate" "$GREEN"
    fi

    log "🔧 Step 4: ตั้งค่าสิทธิ์ไฟล์..." "$CYAN"
    sudo chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null || true
    sudo chmod 644 /etc/ssh/ssh_host_*_key.pub 2>/dev/null || true
    sudo chmod 644 /etc/ssh/sshd_config 2>/dev/null || true
    sudo chown root:root /etc/ssh/sshd_config 2>/dev/null || true
    sudo chown root:root /etc/ssh/ssh_host_* 2>/dev/null || true
    log "✅ ตั้งค่าสิทธิ์ไฟล์เรียบร้อย" "$GREEN"

    log "🧪 Step 5: ทดสอบการตั้งค่า SSH..." "$CYAN"
    if sudo sshd -t; then
        log "✅ การตั้งค่า SSH ถูกต้อง" "$GREEN"
    else
        error_exit "การตั้งค่า SSH ไม่ถูกต้อง"
    fi

    log "🔄 Step 6: รีสตาร์ท SSH service..." "$CYAN"
    local service_restarted=false
    if sudo systemctl restart sshd 2>/dev/null; then
        service_name="sshd"
        service_restarted=true
    elif sudo service sshd restart 2>/dev/null; then
        service_name="sshd"
        service_restarted=true
    fi

    if [[ "$service_restarted" == "true" ]]; then
        log "✅ SSH service ($service_name) รีสตาร์ทเรียบร้อย" "$GREEN"
    else
        warning_log "ไม่สามารถรีสตาร์ท SSH service ได้"
        return 1
    fi

    log "🔍 Step 7: ตรวจสอบสถานะ service..." "$CYAN"
    sleep 3
    if systemctl is-active --quiet sshd 2>/dev/null || pgrep sshd >/dev/null; then
        log "🎉 SSH service กำลังทำงานปกติ!" "$GREEN"
        log "📋 การตั้งค่า SSH ปัจจุบัน:" "$BLUE"
        echo "----------------------------------------"
        sudo grep -E "^(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|UsePAM|X11Forwarding)" /etc/ssh/sshd_config 2>/dev/null || echo "ไม่สามารถอ่านการตั้งค่า SSH ได้"
        echo "----------------------------------------"
        log "✅ Emergency SSH Recovery เสร็จสิ้น!" "$GREEN"
        log "🔒 Root login ถูกเปิดใช้งาน" "$BLUE"
        log "🔑 Password และ key authentication เปิดใช้งาน" "$BLUE"
        log "⚠️ ตรวจสอบให้แน่ใจว่าสามารถ login ด้วย root user และ non-root user ได้!" "$YELLOW"
    else
        error_exit "SSH service ยังไม่ทำงาน"
    fi
}

main() {
    if [[ $EUID -eq 0 ]]; then
        warning_log "กำลังรันด้วยสิทธิ์ root ซึ่งอาจเป็นอันตราย"
    fi

    if ! sudo -v 2>/dev/null; then
        error_exit "ต้องมีสิทธิ์ sudo ในการใช้งาน"
    fi

    if ! check_required_files; then
        error_exit "ไม่สามารถตรวจสอบไฟล์ที่จำเป็นได้"
    fi

    while true; do
        show_main_menu
        echo
        read -p "🎯 กรุณาเลือกหมายเลข (1-8, 99=ฉุกเฉิน): " choice

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
            log "🛠️ เริ่มต้น PAM Advanced Options (P'Aomsin Script)..." "$GREEN"
            run_pam_example_script
            ;;
        7)
            echo
            log "🗂️ เริ่มต้น Advanced Cleanup..." "$GREEN"
            advanced_cleanup
            ;;
        8)
            echo
            log "👋 ขอบคุณที่ใช้งาน PAM Automation Agent V4 - Phase 3" "$GREEN"
            exit 0
            ;;
        99)
            echo
            log "🚨 เริ่มต้น Emergency SSH System Fix..." "$RED"
            emergency_ssh_system_fix
            ;;
        *)
            log "❌ กรุณาเลือกหมายเลข 1-8 หรือ 99 สำหรับฉุกเฉิน" "$RED"
            ;;
        esac

        echo
        read -p "📄 กด Enter เพื่อกลับไปยังเมนูหลัก..."
    done
}

trap 'error_exit "สคริปต์ถูกหยุดโดยผู้ใช้"' INT TERM

main "$@"