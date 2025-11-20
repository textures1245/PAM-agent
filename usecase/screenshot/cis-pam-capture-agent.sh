#!/usr/bin/env bash
# CIS PAM Capture Agent - Main Orchestration Script
# Purpose: Automate CIS compliance evidence capture across multiple VMs
# Author: PAM Automation Team
# Version: 1.0

# Smart bash version check - MUST be at the very top before any arrays
if [[ -n "${BASH_VERSINFO:-}" ]]; then
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
        # Try to find a newer bash
        for bash_path in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash; do
            if [[ -x "$bash_path" ]]; then
                BASH_VER=$("$bash_path" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)
                if [[ -n "$BASH_VER" ]] && [[ "$BASH_VER" -ge 4 ]]; then
                    exec "$bash_path" "$0" "$@"
                    exit $?
                fi
            fi
        done
        echo "❌ ERROR: Bash 4.0+ required (current: ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]})"
        echo "💡 Install: brew install bash"
        exit 1
    fi
fi

# 
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON_FILE="${SCRIPT_DIR}/user_credentials_clean.json"
DATA_ADAPTER="${SCRIPT_DIR}/data-adapter.sh"
TERMSHOT_UTILS="${SCRIPT_DIR}/termshot.sh"
TERMSHOT_DATA="${SCRIPT_DIR}/termshot-data.sh"
LOG_FILE=""
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# User inputs
SSH_USERNAME=""
SSH_KEY_PATH=""

# Global array declarations (MUST be here before any functions)
declare -a TARGET_IPS
declare -A IP_USERS
declare -A IP_GREP_PATTERN
declare -A IP_CHAGE_CMD

# Logging function
log() {
    local message="$1"
    local color="${2:-$NC}"
    echo -e "${color}${message}${NC}"
    if [[ -n "$LOG_FILE" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE"
    fi
}

error_exit() {
    log "❌ ERROR: $1" "$RED"
    exit 1
}

# Function: Check prerequisites
check_prerequisites() {
    log "🔍 Checking prerequisites..." "$BLUE"
    
    # Check JSON file
    if [[ ! -f "$JSON_FILE" ]]; then
        error_exit "JSON file not found: $JSON_FILE"
    fi
    log "  ✓ Found $JSON_FILE" "$GREEN"
    
    # Check data-adapter script
    if [[ ! -f "$DATA_ADAPTER" ]]; then
        error_exit "data-adapter.sh not found: $DATA_ADAPTER"
    fi
    log "  ✓ Found data-adapter.sh" "$GREEN"
    
    # Check termshot utils script
    if [[ ! -f "$TERMSHOT_UTILS" ]]; then
        error_exit "termshot.sh not found: $TERMSHOT_UTILS"
    fi
    log "  ✓ Found termshot.sh" "$GREEN"
    
    # Check required commands
    for cmd in ssh scp jq python3; do
        if ! command -v "$cmd" &>/dev/null; then
            error_exit "Required command not found: $cmd"
        fi
    done
    log "  ✓ All required commands available" "$GREEN"
    
    log "✅ Prerequisites check passed" "$GREEN"
    echo ""
}

# Function: Prompt for user inputs
prompt_user_inputs() {
    log "📝 Please provide SSH connection details" "$BLUE"
    echo ""
    
    # Prompt for SSH username
    while [[ -z "$SSH_USERNAME" ]]; do
        read -p "🔑 SSH Username (required): " SSH_USERNAME
        if [[ -z "$SSH_USERNAME" ]]; then
            log "  ⚠️  Username cannot be empty" "$YELLOW"
        fi
    done
    log "  ✓ Username: $SSH_USERNAME" "$GREEN"
    
    # Prompt for SSH key (optional)
    read -p "🔐 SSH Private Key Path (optional, press Enter to skip): " SSH_KEY_PATH
    
    if [[ -n "$SSH_KEY_PATH" ]]; then
        # Expand tilde
        SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
        
        if [[ ! -f "$SSH_KEY_PATH" ]]; then
            log "  ⚠️  Warning: SSH key file not found: $SSH_KEY_PATH" "$YELLOW"
            read -p "Continue anyway? (y/n): " continue_anyway
            if [[ ! "$continue_anyway" =~ ^[Yy] ]]; then
                error_exit "SSH key file not found"
            fi
        else
            log "  ✓ SSH Key: $SSH_KEY_PATH" "$GREEN"
        fi
    else
        log "  ℹ️  Using default SSH authentication" "$CYAN"
    fi
    
    echo ""
}

# Function: Run data adapter
run_data_adapter() {
    log "🔄 Running data adapter..." "$BLUE"
    
    if ! bash "$DATA_ADAPTER" "$JSON_FILE"; then
        error_exit "Data adapter failed"
    fi
    
    if [[ ! -f "$TERMSHOT_DATA" ]]; then
        error_exit "termshot-data.sh not generated"
    fi
    
    log "✅ Data adapter completed" "$GREEN"
    echo ""
}

# Function: Load data and utilities
load_data_and_utils() {
    log "📦 Loading data and utility functions..." "$BLUE"
    
    # Source termshot-data.sh
    # shellcheck source=/dev/null
    source "$TERMSHOT_DATA"
    log "  ✓ Loaded termshot-data.sh" "$GREEN"
    log "  🔍 DEBUG: TARGET_IPS count after source: ${#TARGET_IPS[@]}" "$CYAN"
    log "  🔍 DEBUG: TARGET_IPS values: ${TARGET_IPS[*]}" "$CYAN"
    
    # Source termshot.sh
    # shellcheck source=/dev/null
    source "$TERMSHOT_UTILS"
    log "  ✓ Loaded termshot.sh" "$GREEN"
    
    echo ""
}

# Function: Capture screenshots for single VM
capture_vm_screenshots() {
    local ip="$1"
    local vm_index="$2"
    local total_vms="$3"
    
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "$PURPLE"
    log "📸 Processing VM $vm_index of $total_vms: $ip" "$CYAN"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "$PURPLE"
    
    # Test SSH connection
    log "  🔌 Testing SSH connection..." "$CYAN"
    if ! test_ssh_connection "$SSH_USERNAME" "$ip" "$SSH_KEY_PATH"; then
        log "  ❌ Cannot connect to $ip, skipping..." "$RED"
        return 1
    fi
    log "  ✅ SSH connection successful" "$GREEN"
    
    # Get VM hostname
    log "  🖥️  Getting VM hostname..." "$CYAN"
    local vm_name
    vm_name=$(get_vm_hostname "$SSH_USERNAME" "$ip" "$SSH_KEY_PATH")
    log "  ✓ VM Name: $vm_name" "$GREEN"
    
    # Create folder name
    local folder_name="${vm_name},${ip}"
    log "  📁 Folder: $folder_name" "$BLUE"
    
    # Create remote folder
    if ! create_remote_folder "$SSH_USERNAME" "$ip" "$SSH_KEY_PATH" "$folder_name"; then
        log "  ❌ Failed to create remote folder, skipping VM" "$RED"
        return 1
    fi
    
    # Install termshot
    if ! install_termshot_on_remote "$SSH_USERNAME" "$ip" "$SSH_KEY_PATH"; then
        log "  ❌ Failed to install termshot, skipping VM" "$RED"
        cleanup_remote_folder "$SSH_USERNAME" "$ip" "$SSH_KEY_PATH" "$folder_name" || true
        return 1
    fi
    
    # Get users for this IP
    local users="${IP_USERS[$ip]}"
    local grep_pattern="${IP_GREP_PATTERN[$ip]}"
    local chage_cmd="${IP_CHAGE_CMD[$ip]}"
    
    log "  👥 Users: $users" "$BLUE"
    
    # Capture Command 1: chage all users
    log "  📷 [1/5] Capturing password expiry for all users..." "$CYAN"
    capture_screenshot_remote "$SSH_USERNAME" "$ip" "$SSH_KEY_PATH" "$folder_name" \
        "$chage_cmd" "01_chage_all_users.png"
    
    # Capture Command 2: ls -l /home
    log "  📷 [2/5] Capturing home directory listing..." "$CYAN"
    capture_screenshot_remote "$SSH_USERNAME" "$ip" "$SSH_KEY_PATH" "$folder_name" \
        "ls -l /home" "02_home_list.png"
    
    # Capture Command 3: SSH & Password Policy
    log "  📷 [3/5] Capturing SSH and password policy..." "$CYAN"
    local cmd3="sudo grep -E 'PermitRootLogin|PasswordAuthentication|PermitEmptyPasswords|X11Forwarding|UseDNS|UsePAM|PrintMotd' /etc/ssh/sshd_config 2>/dev/null || true; echo '---'; grep -E 'minlen|dcredit|ucredit|lcredit|ocredit|enforcing' /etc/security/pwquality.conf 2>/dev/null || true"
    capture_screenshot_remote "$SSH_USERNAME" "$ip" "$SSH_KEY_PATH" "$folder_name" \
        "$cmd3" "03_ssh_pwd_policy.png"
    
    # Capture Command 4: Publickey Auth Logs
    log "  📷 [4/5] Capturing publickey authentication logs..." "$CYAN"
    local cmd4="sudo zgrep -h 'Accepted publickey' /var/log/auth.log* 2>/dev/null | sed 's/RSA SHA256:[^ ]*/RSA/' | sed 's/ED25519 SHA256:[^ ]*/ED25519/' | awk '!seen[\$7]++' | grep -E '$grep_pattern' || echo 'No publickey auth logs found'"
    capture_screenshot_remote "$SSH_USERNAME" "$ip" "$SSH_KEY_PATH" "$folder_name" \
        "$cmd4" "04_publickey_logs.png"
    
    # Capture Command 5: Sudo Session Logs
    log "  📷 [5/5] Capturing sudo session logs..." "$CYAN"
    local cmd5="sudo zgrep 'sudo:session' /var/log/auth.log* 2>/dev/null | grep 'root(uid=0) by' | awk '{split(\$NF, a, \"(\"); if (!seen[a[1]]++) print}' | grep -E '$grep_pattern' || echo 'No sudo session logs found'"
    capture_screenshot_remote "$SSH_USERNAME" "$ip" "$SSH_KEY_PATH" "$folder_name" \
        "$cmd5" "05_sudo_logs.png"
    
    log "  ✅ All screenshots captured" "$GREEN"
    
    # Uninstall termshot
    uninstall_termshot_on_remote "$SSH_USERNAME" "$ip" "$SSH_KEY_PATH"
    
    # Download screenshots
    if ! scp_folder_to_local "$SSH_USERNAME" "$ip" "$SSH_KEY_PATH" "$folder_name" "$SCRIPT_DIR"; then
        log "  ❌ Failed to download screenshots" "$RED"
        cleanup_remote_folder "$SSH_USERNAME" "$ip" "$SSH_KEY_PATH" "$folder_name" || true
        return 1
    fi
    
    # Cleanup remote folder
    cleanup_remote_folder "$SSH_USERNAME" "$ip" "$SSH_KEY_PATH" "$folder_name"
    
    log "  ✅ VM processing completed successfully" "$GREEN"
    echo ""
    
    return 0
}

# Function: Ensure pip3 is installed
ensure_pip3_installed() {
    if ! command -v pip3 &>/dev/null; then
        log "  📦 pip3 not found, installing..." "$YELLOW"
        
        # Detect OS
        if [[ -f /etc/os-release ]]; then
            # shellcheck source=/dev/null
            source /etc/os-release
            
            case "$ID" in
                ubuntu|debian)
                    log "  🔧 Detected Ubuntu/Debian, installing python3-pip..." "$CYAN"
                    if command -v apt-get &>/dev/null; then
                        sudo apt-get update -qq &>/dev/null || true
                        sudo apt-get install -y python3-pip &>/dev/null
                    else
                        error_exit "apt-get not found, cannot install pip3"
                    fi
                    ;;
                fedora|rhel|centos|rocky|almalinux)
                    log "  🔧 Detected Red Hat based distro, installing python3-pip..." "$CYAN"
                    if command -v dnf &>/dev/null; then
                        sudo dnf install -y python3-pip &>/dev/null
                    elif command -v yum &>/dev/null; then
                        sudo yum install -y python3-pip &>/dev/null
                    else
                        error_exit "Package manager not found, cannot install pip3"
                    fi
                    ;;
                *)
                    error_exit "Unsupported OS: $ID. Please install pip3 manually: sudo apt-get install python3-pip"
                    ;;
            esac
        elif [[ "$(uname)" == "Darwin" ]]; then
            log "  🔧 Detected macOS, installing pip3 via python3..." "$CYAN"
            python3 -m ensurepip --upgrade 2>/dev/null || \
                error_exit "Failed to install pip3. Try: python3 -m ensurepip or brew install python3"
        else
            error_exit "Cannot detect OS. Please install pip3 manually"
        fi
        
        # Verify installation
        if ! command -v pip3 &>/dev/null; then
            error_exit "pip3 installation failed. Please install manually: sudo apt-get install python3-pip"
        fi
        
        log "  ✅ pip3 installed successfully" "$GREEN"
    fi
}

# Function: Generate Excel report using Python
generate_excel_report() {
    log "📊 Generating Excel report..." "$BLUE"
    
    # Ensure pip3 is installed
    ensure_pip3_installed
    
    # Check Python dependencies
    log "  📦 Checking Python dependencies..." "$CYAN"
    if ! python3 -c "import openpyxl" 2>/dev/null; then
        log "  📥 Installing openpyxl..." "$YELLOW"
        
        # Try installing via apt first (for Ubuntu/Debian)
        if command -v apt-get &>/dev/null; then
            log "  🔧 Trying to install via apt..." "$CYAN"
            sudo apt-get install -y python3-openpyxl python3-pil &>/dev/null && \
                log "  ✅ Installed via apt" "$GREEN" || {
                    log "  ⚠️  apt install failed, using pip with --break-system-packages..." "$YELLOW"
                    pip3 install --break-system-packages openpyxl pillow -q || \
                        error_exit "Failed to install Python dependencies"
                }
        else
            # For non-Debian systems, use pip directly
            pip3 install openpyxl pillow -q 2>/dev/null || \
                pip3 install --break-system-packages openpyxl pillow -q || \
                error_exit "Failed to install Python dependencies"
        fi
    fi
    log "  ✓ Python dependencies available" "$GREEN"
    
    # Generate Excel file using inline Python script
    local excel_file="cis_pam_evidence_${TIMESTAMP}.xlsx"
    
    log "  ✍️  Creating Excel file: $excel_file" "$CYAN"
    
    python3 << EOF
import os
import glob
import sys
from openpyxl import Workbook
from openpyxl.drawing.image import Image
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.utils import get_column_letter

try:
    # Change to script directory
    os.chdir("${SCRIPT_DIR}")
    
    wb = Workbook()
    ws = wb.active
    ws.title = "CIS PAM Evidence"
    
    # Headers with styling
    headers = ["VM Name", "OS", "Private IP", "Public IP", 
               "Password policy (Expired)", "List users", 
               "Permit root login", "Log Login ด้วย Private Key", 
               "Log sudo su", "Remark"]
    
    ws.append(headers)
    
    # Style header row
    header_fill = PatternFill(start_color="4472C4", end_color="4472C4", fill_type="solid")
    header_font = Font(bold=True, color="FFFFFF", size=25)
    
    for col_num, header in enumerate(headers, 1):
        cell = ws.cell(row=1, column=col_num)
        cell.fill = header_fill
        cell.font = header_font
        cell.alignment = Alignment(horizontal="center", vertical="center")
    
    # Set column widths
    ws.column_dimensions['A'].width = 50  # VM Name
    ws.column_dimensions['B'].width = 30  # OS
    ws.column_dimensions['C'].width = 30  # Private IP
    ws.column_dimensions['D'].width = 30  # Public IP
    ws.column_dimensions['E'].width = 230  # Password policy
    ws.column_dimensions['F'].width = 230  # List users
    ws.column_dimensions['G'].width = 230  # Permit root login
    ws.column_dimensions['H'].width = 230  # Log Login
    ws.column_dimensions['I'].width = 230  # Log sudo su
    ws.column_dimensions['J'].width = 20  # Remark
    
    # Set header row height
    ws.row_dimensions[1].height = 30
    
    # Find all screenshot folders
    folders = sorted([f for f in glob.glob("*,*") if os.path.isdir(f)])
    
    if not folders:
        print("WARNING: No screenshot folders found", file=sys.stderr)
        wb.save("$excel_file")
        sys.exit(0)
    
    print(f"Found {len(folders)} VM folder(s)")
    
    for folder in folders:
        # Parse folder name: VM_NAME,IP
        parts = folder.split(",", 1)
        if len(parts) != 2:
            print(f"WARNING: Invalid folder name format: {folder}", file=sys.stderr)
            continue
        
        vm_name, private_ip = parts
        print(f"Processing: {vm_name} ({private_ip})")
        
        # Add row data
        row_data = [vm_name, "Ubuntu", private_ip, "", "", "", "", "", "", ""]
        ws.append(row_data)
        current_row = ws.max_row
        
        # Set row height for images
        ws.row_dimensions[current_row].height = 800
        
        # Set font size for all cells in this row
        data_font = Font(size=25)
        for col in range(1, 11):  # Columns A to J
            cell = ws.cell(row=current_row, column=col)
            cell.font = data_font
            cell.alignment = Alignment(horizontal="left", vertical="top")
        
        # Image column mapping
        images_map = {
            "01_chage_all_users.png": "E",
            "02_home_list.png": "F",
            "03_ssh_pwd_policy.png": "G",
            "04_publickey_logs.png": "H",
            "05_sudo_logs.png": "I"
        }
        
        # Insert images
        for img_file, col_letter in images_map.items():
            img_path = os.path.join(folder, img_file)
            if os.path.exists(img_path):
                try:
                    img = Image(img_path)
                    # Resize image to fit cell
                    img.width = 1600
                    img.height = 800
                    ws.add_image(img, f"{col_letter}{current_row}")
                    print(f"  ✓ Inserted {img_file}")
                except Exception as e:
                    print(f"  ⚠️  Failed to insert {img_file}: {e}", file=sys.stderr)
            else:
                print(f"  ⚠️  Image not found: {img_file}", file=sys.stderr)
    
    # Save workbook
    wb.save("$excel_file")
    print(f"Excel report saved: $excel_file")
    
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
EOF
    
    if [[ $? -eq 0 ]]; then
        log "  ✅ Excel report generated: $excel_file" "$GREEN"
        log "  📍 Location: ${SCRIPT_DIR}/${excel_file}" "$CYAN"
    else
        error_exit "Failed to generate Excel report"
    fi
    
    echo ""
}

# Main execution
main() {
    # Print banner
    echo ""
    log "═══════════════════════════════════════════════════════════" "$CYAN"
    log "     CIS PAM Capture Agent - Evidence Collection Tool" "$CYAN"
    log "═══════════════════════════════════════════════════════════" "$CYAN"
    echo ""
    
    # Initialize log file
    LOG_FILE="${SCRIPT_DIR}/cis_capture_${TIMESTAMP}.log"
    log "📝 Log file: $LOG_FILE" "$BLUE"
    echo ""
    
    # Step 1: Check prerequisites
    check_prerequisites
    
    # Step 2: Prompt for user inputs
    prompt_user_inputs
    
    # Step 3: Run data adapter
    run_data_adapter
    
    # Step 4: Load data and utilities
    load_data_and_utils
    
    # Debug: Check arrays immediately after loading
    log "🔍 DEBUG after load_data_and_utils in main():" "$YELLOW"
    log "  TARGET_IPS count: ${#TARGET_IPS[@]}" "$YELLOW"
    log "  TARGET_IPS values: ${TARGET_IPS[*]}" "$YELLOW"
    log "  IP_USERS keys: ${!IP_USERS[*]}" "$YELLOW"
    
    # Step 5: Process each VM
    log "🚀 Starting screenshot capture process..." "$BLUE"
    log "  Total VMs to process: ${#TARGET_IPS[@]}" "$CYAN"
    echo ""
    
    local success_count=0
    local fail_count=0
    local vm_index=1
    
    for ip in "${TARGET_IPS[@]}"; do
        if capture_vm_screenshots "$ip" "$vm_index" "${#TARGET_IPS[@]}"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
        ((vm_index++))
    done
    
    # Step 6: Summary
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "$PURPLE"
    log "📊 Capture Summary" "$BLUE"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "$PURPLE"
    log "  ✅ Successful: $success_count" "$GREEN"
    log "  ❌ Failed: $fail_count" "$RED"
    log "  📁 Total: ${#TARGET_IPS[@]}" "$CYAN"
    echo ""
    
    if [[ $success_count -eq 0 ]]; then
        error_exit "No VMs processed successfully"
    fi
    
    # Step 7: Generate Excel report
    generate_excel_report
    
    # Final message
    log "═══════════════════════════════════════════════════════════" "$GREEN"
    log "   ✅ CIS PAM Capture Agent completed successfully!" "$GREEN"
    log "═══════════════════════════════════════════════════════════" "$GREEN"
    log "  📂 Screenshot folders kept for inspection" "$CYAN"
    log "  📊 Excel report ready for review" "$CYAN"
    log "  📝 Full log: $LOG_FILE" "$CYAN"
    echo ""
}

# Run main function
main "$@"
