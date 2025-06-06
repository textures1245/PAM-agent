#!/bin/bash

# PAM Automation Agent - Enhanced version of pam.example.sh
# Author: Based on production-proven pam.example.sh logic
# Purpose: Automated PAM setup with safety mechanisms

# Global variables

USER_LIST_FILE="./user_list.csv"
SSH_KEY_LIST_FILE="./ssh_key_list.csv"
BACKUP_DIR=""

# Tracking arrays for rollback
declare -a CREATED_USERS=()
declare -a MODIFIED_FILES=()
declare -a CREATED_SSH_DIRS=()

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${2:-$NC}$1${NC}"
}

# Error handling
error_exit() {
    log "❌ ERROR: $1" "$RED"
    safe_rollback
    exit 1
}

# Pre-flight validation
pre_flight_validation() {
    log "🔍 Starting pre-flight validation..." "$BLUE"
    
    # Check OS compatibility
    if ! command -v apt-get >/dev/null 2>&1; then
        error_exit "This script requires apt-get (Ubuntu/Debian)"
    fi
    
    # Check required commands
    for cmd in useradd usermod groupadd getent chage sudo systemctl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error_exit "Required command '$cmd' not found"
        fi
    done
    
    # Check sudo access
    if ! sudo -n true 2>/dev/null; then
        error_exit "Script requires sudo access"
    fi

    
    log "✅ Pre-flight validation passed" "$GREEN"
}

# Validate CSV files (Option B - after menu selection)
validate_csv_files() {
    log "📄 Validating CSV files..." "$BLUE"
    
    # Check user_list.csv
    if [[ ! -f "$USER_LIST_FILE" ]]; then
        error_exit "User list file not found: $USER_LIST_FILE"
    fi
    
    if [[ ! -r "$USER_LIST_FILE" ]]; then
        error_exit "Cannot read user list file: $USER_LIST_FILE"
    fi
    
    # Clean Windows line endings (from original logic)
    sed -i 's/\r$//' "$USER_LIST_FILE"
    
    # Check SSH key list
    if [[ ! -f "$SSH_KEY_LIST_FILE" ]]; then
        error_exit "SSH key list file not found: $SSH_KEY_LIST_FILE"
    fi
    
    if [[ ! -r "$SSH_KEY_LIST_FILE" ]]; then
        error_exit "Cannot read SSH key list file: $SSH_KEY_LIST_FILE"
    fi
    
    # Clean Windows line endings
    sed -i 's/\r$//' "$SSH_KEY_LIST_FILE"
    
    # Validate CSV format
    if ! head -1 "$USER_LIST_FILE" | grep -q ","; then
        error_exit "Invalid CSV format in: $USER_LIST_FILE"
    fi
    
    if ! head -1 "$SSH_KEY_LIST_FILE" | grep -q ","; then
        error_exit "Invalid CSV format in: $SSH_KEY_LIST_FILE"
    fi
    
    log "✅ CSV files validation passed" "$GREEN"
}

# Create backup system (Smart backup - reuse existing if present)
create_backup() {
    log "💾 Setting up backup system..." "$BLUE"
    
    # Check if backup already exists (from previous failed run)
    local existing_backup=$(find /tmp -maxdepth 1 -name "pam_backup_*" -type d 2>/dev/null | head -1)
    
    if [[ -n "$existing_backup" ]]; then
        BACKUP_DIR="$existing_backup"
        log "ℹ️  Using existing backup directory: $BACKUP_DIR" "$YELLOW"
    else
        BACKUP_DIR="/tmp/pam_backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        log "✅ Created new backup directory: $BACKUP_DIR" "$GREEN"
    fi
    
    # Backup critical files before modification
    backup_file() {
        local file="$1"
        if [[ -f "$file" ]]; then
            sudo cp "$file" "$BACKUP_DIR/$(basename "$file").bak" 2>/dev/null || true
            log "✅ Backed up $file" "$GREEN"
        fi
    }
    
    backup_file "/etc/sudoers"
    backup_file "/etc/ssh/sshd_config"
    backup_file "/etc/security/pwquality.conf"
    
    # Backup current user/group state
    getent passwd > "$BACKUP_DIR/passwd_before.txt"
    getent group > "$BACKUP_DIR/group_before.txt"
}

# Smart rollback function (Hybrid approach)
safe_rollback() {
    log "🔄 Initiating safe rollback..." "$YELLOW"
    
    # Step 1: Remove created users (most critical)
    for user in "${CREATED_USERS[@]}"; do
        if getent passwd "$user" >/dev/null 2>&1; then
            sudo deluser --remove-home "$user" 2>/dev/null
            log "↩️  Removed user: $user" "$YELLOW"
        fi
    done
    
    # Step 2: Restore critical system files
    if [[ -f "$BACKUP_DIR/sudoers.bak" ]]; then
        sudo cp "$BACKUP_DIR/sudoers.bak" /etc/sudoers
        log "↩️  Restored /etc/sudoers" "$YELLOW"
    fi
    
    if [[ -f "$BACKUP_DIR/sshd_config.bak" ]]; then
        sudo cp "$BACKUP_DIR/sshd_config.bak" /etc/ssh/sshd_config
        sudo systemctl restart sshd
        log "↩️  Restored SSH config and restarted service" "$YELLOW"
    fi
    
    if [[ -f "$BACKUP_DIR/pwquality.conf.bak" ]]; then
        sudo cp "$BACKUP_DIR/pwquality.conf.bak" /etc/security/pwquality.conf
        log "↩️  Restored password quality config" "$YELLOW"
    fi
    
    # Step 3: Clean up created directories
    for dir in "${CREATED_SSH_DIRS[@]}"; do
        if [[ -d "$dir" ]] && [[ "$dir" == /home/*/.ssh ]]; then
            sudo rm -rf "$dir" 2>/dev/null
            log "↩️  Removed SSH directory: $dir" "$YELLOW"
        fi
    done
    
    log "✅ Rollback completed safely" "$GREEN"
}

# Cleanup function (remove backup files but keep CSV files)
cleanup_on_success() {
    log "🧹 Cleaning up backup files..." "$BLUE"
    
    if [[ -n "$BACKUP_DIR" ]] && [[ -d "$BACKUP_DIR" ]]; then
        rm -rf "$BACKUP_DIR"
        log "✅ Removed backup directory: $BACKUP_DIR" "$GREEN"
    fi
    
    log "ℹ️  CSV files preserved: $USER_LIST_FILE and $SSH_KEY_LIST_FILE" "$BLUE"
}

# Core functions extracted from pam.example.sh

# Step 1 & 3: Setup and verify wheel group (from choice "1" and "3")
setup_wheel_group() {
    log "🔧 Setting up wheel group..." "$BLUE"
    
    # Exact logic from pam.example.sh choice "1"
    if ! getent group wheel >/dev/null 2>&1; then
        sudo groupadd wheel
        log "✅ เพิ่ม group 'wheel' เรียบร้อย" "$GREEN"
    else
        log "ℹ️ group 'wheel' มีอยู่แล้ว" "$BLUE"
    fi

    if sudo grep -q "^%wheel\s\+ALL=(ALL)\s\+ALL" /etc/sudoers; then
        log "ℹ️ สิทธิ์ sudo สำหรับ group 'wheel' มีอยู่แล้ว" "$BLUE"
    else
        echo "%wheel  ALL=(ALL)  ALL" | sudo tee -a /etc/sudoers
        MODIFIED_FILES+=("/etc/sudoers")
        log "✅ เพิ่มสิทธิ์ sudo สำหรับ group 'wheel' แล้ว" "$GREEN"
    fi
}

verify_wheel_group() {
    log "🔍 Verifying wheel group setup..." "$BLUE"
    
    # Exact logic from pam.example.sh choice "3"
    if getent group wheel >/dev/null 2>&1; then
        log "✅ Group 'wheel' exists" "$GREEN"
        log "ℹ️ สมาชิกใน group 'wheel' ปัจจุบัน:" "$BLUE"
        sudo getent group wheel
    else
        error_exit "❌ group 'wheel' ยังไม่มีในระบบ"
    fi
}

# Step 7: Create users (exact logic from choice "7")
create_users_from_csv() {
    log "👥 Creating users from CSV..." "$BLUE"
    
    # Ensure wheel group exists first
    if ! getent group wheel >/dev/null 2>&1; then
        sudo groupadd wheel
        log "✅ เพิ่ม group 'wheel' เรียบร้อย" "$GREEN"
    fi
    
    while IFS=, read -r USERNAME PASSWORD; do
        # ข้ามบรรทัดว่าง
        if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
            log "❗ ข้อมูลไม่ครบ (username หรือ password) ข้าม" "$YELLOW"
            continue
        fi

        # ถ้ามี user อยู่แล้ว
        if getent passwd "$USERNAME" >/dev/null 2>&1; then
            log "ℹ️ User '$USERNAME' มีอยู่แล้ว ข้าม" "$BLUE"
            continue
        fi

        # สร้าง user ด้วย useradd และสร้าง home directory ด้วย -m
        sudo useradd -m -s /bin/bash "$USERNAME"
        CREATED_USERS+=("$USERNAME")

        # ตั้งรหัสผ่าน
        echo "$USERNAME:$PASSWORD" | sudo chpasswd

        # ปลดล็อกบัญชี user กรณีถูกล็อก
        sudo passwd -u "$USERNAME" >/dev/null 2>&1

        log "✅ เพิ่ม user '$USERNAME' พร้อมตั้งรหัสผ่านและปลดล็อกบัญชีเรียบร้อย" "$GREEN"

        # ตรวจสอบอีกรอบว่าทำสำเร็จ
        if getent passwd "$USERNAME" >/dev/null 2>&1; then
            log "✅ User '$USERNAME' ถูกสร้างสำเร็จ" "$GREEN"
        else
            error_exit "❌ สร้าง user '$USERNAME' ไม่สำเร็จ"
        fi

        # เพิ่มเข้า group wheel
        sudo usermod -aG wheel "$USERNAME"
        log "✅ เพิ่ม '$USERNAME' เข้า group 'wheel' เรียบร้อย" "$GREEN"

    done < "$USER_LIST_FILE"

    # แสดงสมาชิกใน group wheel
    log "ℹ️ สมาชิกใน group 'wheel' ปัจจุบัน:" "$BLUE"
    sudo getent group wheel

    # ตรวจสอบว่ามีสิทธิ์ sudo ให้ group wheel หรือยัง
    if ! sudo grep -q "^%wheel\s\+ALL=(ALL)\s\+ALL" /etc/sudoers; then
        echo "%wheel  ALL=(ALL)  ALL" | sudo tee -a /etc/sudoers
        MODIFIED_FILES+=("/etc/sudoers")
        log "✅ เพิ่มสิทธิ์ sudo สำหรับ group 'wheel' แล้ว" "$GREEN"
    fi

    log "✅ เสร็จเรียบร้อยทั้งหมด สามารถ su USERNAME และ sudo su ได้เลย" "$GREEN"
}

# Step 9: Verify users (exact logic from choice "9")
verify_users() {
    log "🔍 Verifying users..." "$BLUE"
    
    while IFS=, read -r USERNAME _; do # อ่าน username เท่านั้น ส่วน password ข้าม (_)
        # ข้ามบรรทัดว่าง
        if [[ -z "$USERNAME" ]]; then
            log "❗ พบชื่อ user ว่าง ข้าม" "$YELLOW"
            continue
        fi

        if getent passwd "$USERNAME" >/dev/null 2>&1; then
            log "✅ User '$USERNAME' มีอยู่ในระบบ" "$GREEN"
            log "ℹ️ รายละเอียด:" "$BLUE"
            getent passwd "$USERNAME"

            log "ℹ️ กลุ่มที่สังกัด:" "$BLUE"
            id -nG "$USERNAME"

            if [ -d "/home/$USERNAME" ]; then
                log "📂 Home directory: /home/$USERNAME" "$BLUE"
            else
                log "❌ ไม่มี home directory สำหรับ user นี้" "$RED"
            fi
        else
            error_exit "❌ User '$USERNAME' ไม่มีอยู่ในระบบ"
        fi
    done < "$USER_LIST_FILE"
}

# Step 4: Install libpam-pwquality (exact logic from choice "4")
install_pwquality() {
    log "📦 ติดตั้ง libpam-pwquality..." "$BLUE"
    sudo apt-get update >/dev/null 2>&1
    sudo apt-get install -y libpam-pwquality
    log "✅ ติดตั้ง libpam-pwquality เรียบร้อยแล้ว" "$GREEN"
}

# Step 5: Enable password quality (exact logic from choice "5")
enable_password_quality() {
    log "🔒 ตั้งค่าความปลอดภัยรหัสผ่านใน /etc/security/pwquality.conf..." "$BLUE"
    
    sudo sed -i.bak -e 's/^# *minlen = .*/minlen = 14/' \
        -e 's/^# *dcredit = .*/dcredit = -1/' \
        -e 's/^# *ucredit = .*/ucredit = -1/' \
        -e 's/^# *lcredit = .*/lcredit = -1/' \
        -e 's/^# *ocredit = .*/ocredit = -1/' \
        -e 's/^# *enforcing = .*/enforcing = 1/' /etc/security/pwquality.conf
    
    MODIFIED_FILES+=("/etc/security/pwquality.conf")
    
    log "✅ ตั้งค่าความปลอดภัยเรียบร้อยแล้ว" "$GREEN"
    log "---- แสดงเฉพาะบรรทัดที่เปลี่ยนแปลง ----" "$BLUE"
    sudo grep -E '^(minlen|dcredit|ucredit|lcredit|ocredit|enforcing) ' /etc/security/pwquality.conf
}

# Step 10/11: Set password expiry (exact logic from choice "10" and "11")
set_password_expiry() {
    local days="$1"
    local action_desc="$2"
    
    log "⏰ Setting password expiry ($action_desc)..." "$BLUE"
    
    while IFS= read -r LINE || [[ -n "$LINE" ]]; do
        LINE=$(echo "$LINE" | xargs) # ตัด space หน้าหลัง
        [[ -z "$LINE" ]] && continue # ข้ามบรรทัดว่าง

        IFS=',' read -ra USERS <<<"$LINE"
        for USERNAME in "${USERS[@]}"; do
            USERNAME=$(echo "$USERNAME" | xargs)
            [[ -z "$USERNAME" ]] && continue # ข้ามชื่อว่าง

            # เช็คว่า username เป็น pattern ปกติ a-zA-Z0-9_- เท่านั้น
            if [[ ! "$USERNAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                continue
            fi

            if id "$USERNAME" &>/dev/null; then
                sudo chage -M "$days" -m 0 -W 7 "$USERNAME"
                if [[ "$days" == "90" ]]; then
                    log "✅ ตั้งอายุรหัสผ่าน 90 วันให้ '$USERNAME' สำเร็จ" "$GREEN"
                else
                    log "✅ ยกเลิกรหัสผ่าน 90 วัน ให้ '$USERNAME' สำเร็จ ตั้งเป็น 9999 วัน" "$GREEN"
                fi
                sudo chage -l "$USERNAME"
                log "----------------------------------------" "$BLUE"
            else
                log "❌ ไม่พบ user '$USERNAME'" "$RED"
            fi
        done
    done < "$USER_LIST_FILE"
}

# Step 12: Verify password settings (exact logic from choice "12")
verify_password_settings() {
    log "🔍 Verifying password settings..." "$BLUE"
    
    while IFS= read -r LINE || [[ -n "$LINE" ]]; do
        LINE=$(echo "$LINE" | xargs) # ตัด space หน้าหลัง
        [[ -z "$LINE" ]] && continue # ข้ามบรรทัดว่าง

        IFS=',' read -ra USERS <<<"$LINE"
        for USERNAME in "${USERS[@]}"; do
            USERNAME=$(echo "$USERNAME" | xargs)
            [[ -z "$USERNAME" ]] && continue # ข้ามชื่อว่าง

            # เช็คว่า username เป็น pattern ปกติ a-zA-Z0-9_- เท่านั้น
            if [[ ! "$USERNAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                continue
            fi

            if id "$USERNAME" &>/dev/null; then
                log "📋 ข้อมูล user '$USERNAME':" "$BLUE"
                sudo chage -l "$USERNAME"
                log "----------------------------------------" "$BLUE"
            else
                log "❌ ไม่พบ user '$USERNAME'" "$RED"
            fi
        done
    done < "$USER_LIST_FILE"
}

# Step 13: Install SSH keys (exact logic from choice "13")
install_ssh_keys() {
    log "🔑 Installing SSH keys..." "$BLUE"
    
    declare -A USERS_DONE
    
    while IFS=, read -r USERNAME PUB_KEY; do
        if [[ -z "$USERNAME" || -z "$PUB_KEY" ]]; then
            log "❗ พบข้อมูลไม่ครบ ข้าม" "$YELLOW"
            continue
        fi
        
        if ! id "$USERNAME" >/dev/null 2>&1; then
            log "❌ User '$USERNAME' ไม่มีอยู่ในระบบ" "$RED"
            continue
        fi
        
        SSH_DIR="/home/$USERNAME/.ssh"
        AUTH_KEYS="$SSH_DIR/authorized_keys"
        
        if [[ ! -d "$SSH_DIR" ]]; then
            log "🔧 กำลังเตรียมโฟลเดอร์ $SSH_DIR ให้ '$USERNAME'" "$BLUE"
            sudo mkdir -p "$SSH_DIR"
            sudo chmod 700 "$SSH_DIR"
            sudo touch "$AUTH_KEYS"
            sudo chmod 600 "$AUTH_KEYS"
            sudo chown -R "$USERNAME":"$USERNAME" "$SSH_DIR"
            CREATED_SSH_DIRS+=("$SSH_DIR")
        fi
        
        # เพิ่ม key ลงไปเลย ไม่ต้องเช็ก
        echo "$PUB_KEY" | sudo tee -a "$AUTH_KEYS" >/dev/null
        log "✅ เพิ่ม public key ให้ '$USERNAME' เรียบร้อย" "$GREEN"
        
        USERS_DONE["$USERNAME"]=1
        
    done < "$SSH_KEY_LIST_FILE"
    
    log "✅ ดำเนินการเสร็จสิ้น" "$GREEN"
    
    log "📂 ตรวจสอบเนื้อหา authorized_keys ของแต่ละ user:" "$BLUE"
    for USERNAME in "${!USERS_DONE[@]}"; do
        log "🔸 $USERNAME:" "$BLUE"
        sudo cat "/home/$USERNAME/.ssh/authorized_keys"
        log "--------------------------" "$BLUE"
    done
}

# Step 15: Verify SSH keys (exact logic from choice "15")
verify_ssh_keys() {
    log "🔍 Verifying SSH keys..." "$BLUE"
    
    declare -A USERS_PROCESSED
    
    while IFS=, read -r USERNAME _; do
        # ข้ามบรรทัดว่าง หรือชื่อซ้ำ
        if [[ -z "$USERNAME" || -n "${USERS_PROCESSED[$USERNAME]}" ]]; then
            continue
        fi
        
        USERS_PROCESSED[$USERNAME]=1
        
        # ตรวจสอบว่า user มีอยู่จริงหรือไม่
        if ! id "$USERNAME" >/dev/null 2>&1; then
            log "❌ User '$USERNAME' ไม่มีอยู่ในระบบ" "$RED"
            continue
        fi
        
        AUTH_KEYS="/home/$USERNAME/.ssh/authorized_keys"
        
        if sudo test -f "$AUTH_KEYS"; then
            log "✅ พบไฟล์ '$AUTH_KEYS' ของ user '$USERNAME'" "$GREEN"
            log "ℹ️ เนื้อหาในไฟล์:" "$BLUE"
            sudo cat "$AUTH_KEYS"
            log "--------------------------------------" "$BLUE"
        else
            log "ℹ️ ไม่พบไฟล์ '$AUTH_KEYS' ของ user '$USERNAME'" "$YELLOW"
        fi
        
    done < "$SSH_KEY_LIST_FILE"
    
    log "✅ ดำเนินการเสร็จสิ้น" "$GREEN"
}

# Step 16: SSH hardening (exact logic from choice "16")
configure_ssh_security() {
    log "🔧 กำลังแก้ไขไฟล์ /etc/ssh/sshd_config ..." "$BLUE"
    
    sudo sed -i.bak -E \
        -e 's/^#?PermitRootLogin.*/PermitRootLogin no/' \
        -e 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' \
        -e 's/^#?PermitEmptyPasswords.*/PermitEmptyPasswords no/' \
        -e 's/^#?X11Forwarding.*/X11Forwarding no/' \
        -e 's/^#?UseDNS.*/UseDNS no/' \
        -e 's/^#?UsePAM.*/UsePAM yes/' \
        /etc/ssh/sshd_config
    
    MODIFIED_FILES+=("/etc/ssh/sshd_config")
    
    log "🔄 กำลัง restart sshd ..." "$BLUE"
    sudo systemctl restart sshd
    
    log "✅ ตั้งค่า ssh และ restart sshd สำเร็จ" "$GREEN"
}

# Check if PAM creation was completed (Option C - Comprehensive validation)
check_pam_creation_status() {
    local issues=0
    
    log "🔍 Checking PAM creation status..." "$BLUE"
    
    # Check wheel group exists
    if ! getent group wheel >/dev/null 2>&1; then
        log "❌ Wheel group not found" "$RED"
        ((issues++))
    fi
    
    # Check sudo permissions
    if ! sudo grep -q "^%wheel\s\+ALL=(ALL)\s\+ALL" /etc/sudoers; then
        log "❌ Sudo permissions for wheel group not found" "$RED"
        ((issues++))
    fi
    
    # Check users from CSV exist and are in wheel group
    while IFS=, read -r USERNAME _; do
        [[ -z "$USERNAME" ]] && continue
        
        if ! getent passwd "$USERNAME" >/dev/null 2>&1; then
            log "❌ User '$USERNAME' not found" "$RED"
            ((issues++))
        elif ! id -nG "$USERNAME" | grep -qw "wheel"; then
            log "❌ User '$USERNAME' not in wheel group" "$RED"
            ((issues++))
        fi
    done < "$USER_LIST_FILE"
    
    # Check SSH keys
    while IFS=, read -r USERNAME _; do
        [[ -z "$USERNAME" ]] && continue
        
        AUTH_KEYS="/home/$USERNAME/.ssh/authorized_keys"
        if ! sudo test -f "$AUTH_KEYS"; then
            log "❌ SSH keys not found for user '$USERNAME'" "$RED"
            ((issues++))
        fi
    done < "$SSH_KEY_LIST_FILE"
    
    if [[ $issues -eq 0 ]]; then
        log "✅ PAM creation verification passed" "$GREEN"
        return 0
    else
        log "❌ PAM creation verification failed ($issues issues found)" "$RED"
        return $issues
    fi
}

# Status check function (Option 3)
show_pam_status() {
    log "🔍 Current PAM Status Report" "$BLUE"
    log "============================" "$BLUE"
    
    # Wheel group status
    if getent group wheel >/dev/null 2>&1; then
        log "✅ Wheel group exists" "$GREEN"
        log "ℹ️ Members:" "$BLUE"
        sudo getent group wheel
    else
        log "❌ Wheel group not found" "$RED"
    fi
    
    echo
    
    # Sudo permissions
    if sudo grep -q "^%wheel\s\+ALL=(ALL)\s\+ALL" /etc/sudoers; then
        log "✅ Sudo permissions configured" "$GREEN"
    else
        log "❌ Sudo permissions not found" "$RED"
    fi
    
    echo
    
    # Users status
    log "👥 Users Status:" "$BLUE"
    while IFS=, read -r USERNAME _; do
        [[ -z "$USERNAME" ]] && continue
        
        if getent passwd "$USERNAME" >/dev/null 2>&1; then
            log "✅ User '$USERNAME' exists" "$GREEN"
            
            if id -nG "$USERNAME" | grep -qw "wheel"; then
                log "  ✅ In wheel group" "$GREEN"
            else
                log "  ❌ Not in wheel group" "$RED"
            fi
            
            # Check SSH keys
            AUTH_KEYS="/home/$USERNAME/.ssh/authorized_keys"
            if sudo test -f "$AUTH_KEYS"; then
                log "  ✅ SSH keys configured" "$GREEN"
            else
                log "  ❌ SSH keys not found" "$RED"
            fi
            
            # Password expiry
            local max_days=$(sudo chage -l "$USERNAME" | grep "Maximum number of days" | awk '{print $NF}')
            log "  ℹ️  Password expires in: $max_days days" "$BLUE"
        else
            log "❌ User '$USERNAME' not found" "$RED"
        fi
    done < "$USER_LIST_FILE"
    
    echo
    
    # SSH configuration
    log "🔒 SSH Configuration:" "$BLUE"
    sudo grep -E "PermitRootLogin|PasswordAuthentication|PermitEmptyPasswords|X11Forwarding|UseDNS|UsePAM" /etc/ssh/sshd_config
    
    echo
    log "✅ Status report completed" "$GREEN"
}

# Main menu
show_menu() {
    echo
    log "=====================================" "$BLUE"
    log "     PAM Automation Agent" "$BLUE"
    log "=====================================" "$BLUE"
    echo "1) PAM Creation (Complete Setup)"
    echo "2) SSH Security Hardening" 
    echo "3) Show PAM Status"
    echo "0) Exit"
    log "=====================================" "$BLUE"
}

# PAM Creation workflow (Option 1)
pam_creation_workflow() {
    log "🚀 Starting PAM Creation Workflow..." "$BLUE"
    
    # Load and validate CSV files (Option B - after selection)
    validate_csv_files
    
    # Get user parameters
    echo
    read -rp "Install libpam-pwquality and enable password quality? (1=Yes, 0=No): " ENABLE_PWQUALITY
    read -rp "Set password expiry (1=90 days, 0=9999 days): " PASSWORD_EXPIRY
    
    # Validate inputs
    if [[ "$ENABLE_PWQUALITY" != "0" && "$ENABLE_PWQUALITY" != "1" ]]; then
        error_exit "Invalid input for pwquality (must be 0 or 1)"
    fi
    
    if [[ "$PASSWORD_EXPIRY" != "0" && "$PASSWORD_EXPIRY" != "1" ]]; then
        error_exit "Invalid input for password expiry (must be 0 or 1)"
    fi
    
    # Create backup system
    create_backup
    
    # Set trap for automatic rollback on failure
    trap 'safe_rollback; exit 1' ERR
    
    # Execute PAM creation workflow: 3→1→3→9→7→4*→5*→12→10/11→12→15→13→15
    
    log "📋 Starting PAM creation workflow: 3→1→3→9→7→4*→5*→12→10/11→12→15→13→15" "$BLUE"
    
    # Step 3: Check wheel group (initial verification)
    log "🔍 Step 3: Initial wheel group check..." "$BLUE"
    verify_wheel_group 2>/dev/null || log "ℹ️  Wheel group doesn't exist yet - will be created" "$BLUE"
    
    # Step 1: Setup wheel group
    log "🔧 Step 1: Setup wheel group..." "$BLUE"
    setup_wheel_group
    
    # Step 3: Verify wheel group (after setup)
    log "🔍 Step 3: Verify wheel group setup..." "$BLUE"
    verify_wheel_group
    
    # Step 9: Verify users (check current state)
    log "🔍 Step 9: Check current user state..." "$BLUE"
    # Note: This will show current state, users will be created in Step 7
    
    # Step 7: Create users
    log "👥 Step 7: Create users from CSV..." "$BLUE"
    create_users_from_csv
    
    # Step 4*: Optional - Install libpam-pwquality
    if [[ "$ENABLE_PWQUALITY" == "1" ]]; then
        log "📦 Step 4: Install libpam-pwquality..." "$BLUE"
        install_pwquality
        
        # Step 5*: Optional - Enable password quality
        log "🔒 Step 5: Enable password quality..." "$BLUE"
        enable_password_quality
    else
        log "⏭️  Steps 4 & 5: Skipped (pwquality disabled by user)" "$YELLOW"
    fi
    
    # Step 12: Check password settings (before setting expiry)
    log "🔍 Step 12: Check current password settings..." "$BLUE"
    verify_password_settings
    
    # Step 10/11: Set password expiry based on user input
    if [[ "$PASSWORD_EXPIRY" == "1" ]]; then
        log "⏰ Step 10: Set 90-day password expiry..." "$BLUE"
        set_password_expiry 90 "90 days"
    else
        log "⏰ Step 11: Set 9999-day password expiry..." "$BLUE"
        set_password_expiry 9999 "9999 days"
    fi
    
    # Step 12: Verify password settings (after setting expiry)
    log "🔍 Step 12: Verify password settings after expiry change..." "$BLUE"
    verify_password_settings
    
    # Step 15: Check SSH keys (before installation)
    log "🔍 Step 15: Check current SSH key state..." "$BLUE"
    verify_ssh_keys 2>/dev/null || log "ℹ️  No SSH keys found yet - will be installed" "$BLUE"
    
    # Step 13: Install SSH keys
    log "🔑 Step 13: Install SSH keys..." "$BLUE"
    install_ssh_keys
    
    # Step 15: Verify SSH keys (after installation)
    log "🔍 Step 15: Verify SSH keys after installation..." "$BLUE"
    verify_ssh_keys
    
    # Final verification (Option C - Comprehensive)
    log "🔍 Final comprehensive verification..." "$BLUE"
    if ! check_pam_creation_status; then
        error_exit "PAM creation verification failed"
    fi
    
    # Success! Clean up
    trap - ERR  # Remove error trap
    cleanup_on_success
    
    log "🎉 PAM Creation completed successfully!" "$GREEN"
    log "ℹ️  You can now run Option 2 to configure SSH security" "$BLUE"
}

# SSH hardening workflow (Option 2)
ssh_hardening_workflow() {
    log "🔒 Starting SSH Security Hardening..." "$BLUE"
    
    # Load and validate CSV files for verification (Option B)
    validate_csv_files
    
    # Check if PAM creation was completed (Option C - Comprehensive validation)
    log "🔍 Checking if PAM creation is ready..." "$BLUE"
    if ! check_pam_creation_status; then
        log "❌ PAM creation not completed or has issues" "$RED"
        log "ℹ️  Please run Option 1 (PAM Creation) first" "$BLUE"
        return 1
    fi
    
    log "✅ PAM creation verified - proceeding with SSH hardening" "$GREEN"
    
    # Create backup if needed
    create_backup
    
    # Set trap for automatic rollback on failure
    trap 'safe_rollback; exit 1' ERR
    
    # Configure SSH security (Step 16)
    log "🔒 Step 16: Configure SSH security..." "$BLUE"
    configure_ssh_security
    
    # Success! Clean up
    trap - ERR  # Remove error trap
    cleanup_on_success
    
    log "🎉 SSH Security Hardening completed successfully!" "$GREEN"
    log "⚠️  SSH password authentication is now DISABLED" "$YELLOW"
    log "ℹ️  Make sure you can login via SSH keys before closing this session" "$BLUE"
}

# Main execution
main() {
    # Initial pre-flight validation
    pre_flight_validation
    
    while true; do
        show_menu
        read -rp "Select option (0-3): " choice
        
        case "$choice" in
            1)
                pam_creation_workflow
                ;;
            2)
                ssh_hardening_workflow
                ;;
            3)
                validate_csv_files
                show_pam_status
                ;;
            0)
                log "👋 Goodbye!" "$BLUE"
                exit 0
                ;;
            *)
                log "❌ Invalid choice. Please select 0-3" "$RED"
                ;;
        esac
        
        echo
        read -rp "Press Enter to continue..."
    done
}

# Run main function
main "$@"