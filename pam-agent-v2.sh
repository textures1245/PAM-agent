#!/bin/bash

# PAM Automation Agent V2 - Project-based CSV approach
# Author: Enhanced from pam-agent.sh with bug fixes and new features
# Purpose: Automated PAM setup with project-based user management
#
# KEY IMPROVEMENTS IN V2:
# - Single CSV file approach: full_user_list.csv (project_group,username,password,ssh_public_key)
# - Project-based interactive workflow
# - SSH key override (not append) - FIXED BUG
# - SSH key verification in status checks - FIXED BUG
# - Orphaned user detection and management
# - Timestamped backups (not cleanup after success)
# - Enhanced rollback capabilities
#
# Workflow: 3 → 1 → 3 → 9 → 7 → 4* -> 5* -> 12 → 10 → 12 → 15 → 13 → 15 → 16

set -euo pipefail

# Global variables
FULL_USER_LIST="full_user_list.csv"
BACKUP_DIR=""
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Tracking arrays for rollback
declare -a CREATED_USERS=()
declare -a MODIFIED_FILES=()
declare -a CREATED_SSH_DIRS=()
declare -a PROCESSED_USERS=()

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging function with file output
log() {
    local message="$1"
    local color="${2:-$NC}"

    echo -e "${color}${message}${NC}"
}

# Error handling with enhanced rollback
error_exit() {
    log "❌ ERROR: $1" "$RED"
    log "🔄 Initiating safe rollback..." "$YELLOW"
    safe_rollback
    exit 1
}

# Enhanced logging for actions
action_log() {
    log "🎯 ACTION: $1" "$GREEN"
}

info_log() {
    log "ℹ️  INFO: $1" "$CYAN"
}

warning_log() {
    log "⚠️  WARNING: $1" "$YELLOW"
}

# Pre-flight validation with enhanced checks
pre_flight_validation() {
    log "🔍 Starting pre-flight validation..." "$BLUE"

    # Check OS compatibility
    if ! command -v apt-get >/dev/null 2>&1; then
        error_exit "This script requires apt-get (Ubuntu/Debian)"
    fi

    # Check required commands
    for cmd in useradd usermod groupadd getent chage sudo systemctl awk cut grep; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error_exit "Required command '$cmd' not found"
        fi
    done

    # Check sudo access
    if ! sudo -n true 2>/dev/null; then
        error_exit "Script requires sudo access"
    fi

    # Check if running as root (should not be)
    if [[ $EUID -eq 0 ]]; then
        error_exit "Do not run this script as root. Run with sudo privileges instead."
    fi

    log "✅ Pre-flight validation passed" "$GREEN"
}

# Validate full user list CSV file
validate_full_user_list() {
    log "📄 Validating full user list CSV..." "$BLUE"

    if [[ ! -f "$FULL_USER_LIST" ]]; then
        error_exit "Full user list file not found: $FULL_USER_LIST"
    fi

    if [[ ! -r "$FULL_USER_LIST" ]]; then
        error_exit "Cannot read full user list file: $FULL_USER_LIST"
    fi

    # Clean Windows line endings
    sed -i 's/\r$//' "$FULL_USER_LIST"

    # Validate CSV format (should have 4 columns: project_group,username,password,ssh_public_key)
    local line_count=0
    while IFS=',' read -r project_group username password ssh_key || [[ -n "$project_group" ]]; do
        ((line_count++))

        # Skip empty lines
        [[ -z "$project_group" ]] && continue

        # Validate required fields
        if [[ -z "$project_group" || -z "$username" || -z "$password" ]]; then
            error_exit "Invalid CSV format at line $line_count: Missing required fields (project_group,username,password required)"
        fi

        # Validate username format
        if ! [[ "$username" =~ ^[a-z][a-z0-9_-]*$ ]]; then
            error_exit "Invalid username format at line $line_count: '$username' (must start with lowercase letter, contain only lowercase letters, numbers, hyphens, underscores)"
        fi

    done <"$FULL_USER_LIST"

    log "✅ Full user list validation passed" "$GREEN"
}

# Get unique project groups from CSV
get_project_groups() {
    awk -F',' '{print $1}' "$FULL_USER_LIST" | sort -u | grep -v '^$'
}

# Get users for a specific project group
get_users_by_project() {
    local project_group="$1"
    grep "^${project_group}," "$FULL_USER_LIST" || true
}

# Interactive project selection
select_project_group() {
    log "🎯 Available project groups:" "$PURPLE"

    local projects=()
    while IFS= read -r project; do
        projects+=("$project")
    done < <(get_project_groups)

    if [[ ${#projects[@]} -eq 0 ]]; then
        error_exit "No project groups found in $FULL_USER_LIST"
    fi

    # Display project options
    for i in "${!projects[@]}"; do
        local project="${projects[$i]}"
        local user_count=$(get_users_by_project "$project" | wc -l)
        log "$((i + 1)). $project ($user_count users)" "$CYAN"
    done
    log "$((${#projects[@]} + 1)). All projects" "$CYAN"

    # Get user selection
    while true; do
        echo -n "Select project group (1-$((${#projects[@]} + 1))): "
        read -r selection

        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le $((${#projects[@]} + 1)) ]]; then
            if [[ "$selection" -eq $((${#projects[@]} + 1)) ]]; then
                echo "ALL"
                return
            else
                echo "${projects[$((selection - 1))]}"
                return
            fi
        else
            warning_log "Invalid selection. Please enter a number between 1 and $((${#projects[@]} + 1))"
        fi
    done
}

# Display users for confirmation
display_selected_users() {
    local project_group="$1"

    log "👥 Selected users for processing:" "$BLUE"

    if [[ "$project_group" == "ALL" ]]; then
        log "📋 All users from all projects:" "$PURPLE"
        cat "$FULL_USER_LIST" | while IFS=',' read -r proj user pass ssh_key; do
            [[ -z "$proj" ]] && continue
            local key_status="❌ No SSH key"
            [[ -n "$ssh_key" ]] && key_status="✅ SSH key present"
            log "  • [$proj] $user - $key_status" "$CYAN"
        done
    else
        log "📋 Users in project '$project_group':" "$PURPLE"
        get_users_by_project "$project_group" | while IFS=',' read -r proj user pass ssh_key; do
            local key_status="❌ No SSH key"
            [[ -n "$ssh_key" ]] && key_status="✅ SSH key present"
            log "  • $user - $key_status" "$CYAN"
        done
    fi

    echo -n "Continue with these users? (y/N): "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "Operation cancelled by user" "$YELLOW"
        exit 0
    fi
}

# Create timestamped backup directory
create_backup_dir() {
    BACKUP_DIR="/tmp/pam_backup_${TIMESTAMP}"
    mkdir -p "$BACKUP_DIR"
    MODIFIED_FILES+=("$BACKUP_DIR")
    log "📁 Created backup directory: $BACKUP_DIR" "$GREEN"
}

# Backup a file before modification
backup_file() {
    local file_path="$1"
    if [[ -f "$file_path" ]]; then
        local backup_path="$BACKUP_DIR/$(basename "$file_path").backup"
        cp "$file_path" "$backup_path"
        MODIFIED_FILES+=("$file_path")
        log "💾 Backed up: $file_path -> $backup_path" "$GREEN"
    fi
}

# Step 3: Check current PAM and SSH status (Enhanced with SSH key verification)
check_pam_ssh_status() {
    log "🔍 Step 3: Checking current PAM and SSH status..." "$BLUE"

    local all_users_exist=true
    local all_pam_configured=true
    local all_ssh_configured=true
    local selected_project="$1"

    # Get user list based on selection
    local user_data=""
    if [[ "$selected_project" == "ALL" ]]; then
        user_data=$(cat "$FULL_USER_LIST")
    else
        user_data=$(get_users_by_project "$selected_project")
    fi

    echo "$user_data" | while IFS=',' read -r project_group username password ssh_key; do
        [[ -z "$username" ]] && continue

        info_log "Checking user: $username"

        # Check if user exists
        if ! id "$username" >/dev/null 2>&1; then
            warning_log "User $username does not exist"
            all_users_exist=false
        else
            log "  ✅ User exists" "$GREEN"

            # Check wheel group membership
            if groups "$username" | grep -q '\bwheel\b'; then
                log "  ✅ User in wheel group" "$GREEN"
            else
                warning_log "  User $username not in wheel group"
                all_pam_configured=false
            fi

            # Check password policy
            if sudo chage -l "$username" 2>/dev/null | grep -q "Password expires.*never"; then
                warning_log "  Password policy not configured for $username"
                all_pam_configured=false
            else
                log "  ✅ Password policy configured" "$GREEN"
            fi

            # Check SSH key if provided - FIXED BUG: Now properly checking SSH keys
            if [[ -n "$ssh_key" ]]; then
                local ssh_dir="/home/$username/.ssh"
                local auth_keys="$ssh_dir/authorized_keys"

                if [[ -f "$auth_keys" ]]; then
                    # Extract the key part (remove key type and comment)
                    local key_part=$(echo "$ssh_key" | awk '{print $2}')
                    if grep -q "$key_part" "$auth_keys"; then
                        log "  ✅ SSH key configured" "$GREEN"
                    else
                        warning_log "  SSH key not found in authorized_keys for $username"
                        all_ssh_configured=false
                    fi
                else
                    warning_log "  SSH authorized_keys file not found for $username"
                    all_ssh_configured=false
                fi
            fi
        fi
    done

    # Summary
    log "📊 Status Summary:" "$PURPLE"
    [[ "$all_users_exist" == "true" ]] && log "✅ All users exist" "$GREEN" || log "❌ Some users missing" "$RED"
    [[ "$all_pam_configured" == "true" ]] && log "✅ PAM fully configured" "$GREEN" || log "❌ PAM configuration incomplete" "$RED"
    [[ "$all_ssh_configured" == "true" ]] && log "✅ SSH fully configured" "$GREEN" || log "❌ SSH configuration incomplete" "$RED"

    # Return status for automation decision
    if [[ "$all_users_exist" == "true" && "$all_pam_configured" == "true" && "$all_ssh_configured" == "true" ]]; then
        return 0 # All complete
    else
        return 1 # Needs configuration
    fi
}

# Step 1: Install required PAM packages
install_pam_packages() {
    log "📦 Step 1: Installing required PAM packages..." "$BLUE"

    backup_file "/var/log/apt/history.log"

    local packages=(
        "libpam-pwquality"
        "libpam-modules-bin"
        "ssh"
        "openssh-server"
    )

    for package in "${packages[@]}"; do
        if dpkg -l | grep -q "^ii.*$package"; then
            log "✅ $package already installed" "$GREEN"
        else
            action_log "Installing $package..."
            if sudo apt-get update && sudo apt-get install -y "$package"; then
                log "✅ Successfully installed $package" "$GREEN"
            else
                error_exit "Failed to install $package"
            fi
        fi
    done
}

# Step 9: Configure wheel group and sudo
configure_wheel_group() {
    log "⚙️  Step 9: Configuring wheel group and sudo..." "$BLUE"

    # Create wheel group if it doesn't exist
    if ! getent group wheel >/dev/null; then
        action_log "Creating wheel group..."
        sudo groupadd wheel
        log "✅ Wheel group created" "$GREEN"
    else
        log "✅ Wheel group already exists" "$GREEN"
    fi

    # Configure sudo for wheel group
    local sudoers_wheel="/etc/sudoers.d/wheel"
    backup_file "$sudoers_wheel"

    if [[ ! -f "$sudoers_wheel" ]] || ! grep -q "^%wheel" "$sudoers_wheel"; then
        action_log "Configuring sudo for wheel group..."
        echo "%wheel ALL=(ALL:ALL) ALL" | sudo tee "$sudoers_wheel" >/dev/null
        sudo chmod 440 "$sudoers_wheel"

        # Validate sudoers syntax
        if sudo visudo -c; then
            log "✅ Sudo configuration for wheel group completed" "$GREEN"
        else
            error_exit "Invalid sudoers syntax"
        fi
    else
        log "✅ Sudo already configured for wheel group" "$GREEN"
    fi
}

# Step 7: Configure PAM password policy
configure_pam_policy() {
    log "🔐 Step 7: Configuring PAM password policy..." "$BLUE"

    local pam_common_password="/etc/pam.d/common-password"
    backup_file "$pam_common_password"

    # Check if pwquality is already configured
    if grep -q "pam_pwquality.so" "$pam_common_password"; then
        log "✅ PAM pwquality already configured" "$GREEN"
    else
        action_log "Adding PAM pwquality configuration..."

        # Add pwquality line after pam_unix.so
        sudo sed -i '/pam_unix.so/a password        requisite       pam_pwquality.so retry=3 minlen=8 difok=3 ucredit=-1 lcredit=-1 dcredit=-1 ocredit=-1' "$pam_common_password"

        log "✅ PAM password policy configured" "$GREEN"
    fi

    # Configure pwquality.conf
    local pwquality_conf="/etc/security/pwquality.conf"
    backup_file "$pwquality_conf"

    action_log "Configuring pwquality.conf..."
    sudo tee "$pwquality_conf" >/dev/null <<'EOF'
# Password quality requirements
minlen = 8
minclass = 3
maxrepeat = 2
maxsequence = 3
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
difok = 3
retry = 3
EOF

    log "✅ Password quality configuration completed" "$GREEN"
}

# Step 4: Create user accounts
create_user_accounts() {
    log "👤 Step 4: Creating user accounts..." "$BLUE"

    local selected_project="$1"
    local user_data=""

    if [[ "$selected_project" == "ALL" ]]; then
        user_data=$(cat "$FULL_USER_LIST")
    else
        user_data=$(get_users_by_project "$selected_project")
    fi

    echo "$user_data" | while IFS=',' read -r project_group username password ssh_key; do
        [[ -z "$username" ]] && continue

        if id "$username" >/dev/null 2>&1; then
            log "✅ User $username already exists" "$GREEN"
        else
            action_log "Creating user: $username"

            if sudo useradd -m -s /bin/bash "$username"; then
                CREATED_USERS+=("$username")
                log "✅ User $username created successfully" "$GREEN"

                # Set password
                if echo "$username:$password" | sudo chpasswd; then
                    log "✅ Password set for $username" "$GREEN"
                else
                    error_exit "Failed to set password for $username"
                fi
            else
                error_exit "Failed to create user $username"
            fi
        fi

        PROCESSED_USERS+=("$username")
    done
}

# Step 5: Configure user groups and permissions
configure_user_groups() {
    log "👥 Step 5: Configuring user groups and permissions..." "$BLUE"

    local selected_project="$1"
    local user_data=""

    if [[ "$selected_project" == "ALL" ]]; then
        user_data=$(cat "$FULL_USER_LIST")
    else
        user_data=$(get_users_by_project "$selected_project")
    fi

    echo "$user_data" | while IFS=',' read -r project_group username password ssh_key; do
        [[ -z "$username" ]] && continue

        action_log "Configuring groups for user: $username"

        # Add to wheel group
        if sudo usermod -aG wheel "$username"; then
            log "✅ Added $username to wheel group" "$GREEN"
        else
            error_exit "Failed to add $username to wheel group"
        fi

        # Set password aging policy
        if sudo chage -M 90 -m 1 -W 7 "$username"; then
            log "✅ Password aging policy set for $username" "$GREEN"
        else
            error_exit "Failed to set password aging policy for $username"
        fi
    done
}

# Step 12: Setup SSH directories and permissions
setup_ssh_directories() {
    log "🔑 Step 12: Setting up SSH directories..." "$BLUE"

    local selected_project="$1"
    local user_data=""

    if [[ "$selected_project" == "ALL" ]]; then
        user_data=$(cat "$FULL_USER_LIST")
    else
        user_data=$(get_users_by_project "$selected_project")
    fi

    echo "$user_data" | while IFS=',' read -r project_group username password ssh_key; do
        [[ -z "$username" ]] && continue

        local ssh_dir="/home/$username/.ssh"

        if [[ ! -d "$ssh_dir" ]]; then
            action_log "Creating SSH directory for $username"
            sudo mkdir -p "$ssh_dir"
            CREATED_SSH_DIRS+=("$ssh_dir")
        fi

        # Set proper ownership and permissions
        sudo chown "$username:$username" "$ssh_dir"
        sudo chmod 700 "$ssh_dir"

        log "✅ SSH directory configured for $username" "$GREEN"
    done
}

# Step 10: Configure SSH public keys (FIXED: Override instead of append)
configure_ssh_keys() {
    log "🔐 Step 10: Configuring SSH public keys..." "$BLUE"

    local selected_project="$1"
    local user_data=""

    if [[ "$selected_project" == "ALL" ]]; then
        user_data=$(cat "$FULL_USER_LIST")
    else
        user_data=$(get_users_by_project "$selected_project")
    fi

    echo "$user_data" | while IFS=',' read -r project_group username password ssh_key; do
        [[ -z "$username" ]] && continue

        if [[ -n "$ssh_key" ]]; then
            local ssh_dir="/home/$username/.ssh"
            local auth_keys="$ssh_dir/authorized_keys"

            action_log "Configuring SSH key for $username"

            # FIXED BUG: Override the authorized_keys file instead of appending
            backup_file "$auth_keys"

            # Write the SSH key (overriding existing content)
            echo "$ssh_key" | sudo tee "$auth_keys" >/dev/null

            # Set proper ownership and permissions
            sudo chown "$username:$username" "$auth_keys"
            sudo chmod 600 "$auth_keys"

            log "✅ SSH key configured for $username (overridden)" "$GREEN"
        else
            info_log "No SSH key provided for $username, skipping"
        fi
    done
}

# Step 15: Configure SSH daemon
configure_ssh_daemon() {
    log "🌐 Step 15: Configuring SSH daemon..." "$BLUE"

    local sshd_config="/etc/ssh/sshd_config"
    backup_file "$sshd_config"

    # Create a backup
    sudo cp "$sshd_config" "$sshd_config.backup.$(date +%Y%m%d_%H%M%S)"

    action_log "Applying SSH hardening configuration..."

    # Apply SSH hardening settings
    sudo tee -a "$sshd_config" >/dev/null <<'EOF'

# PAM Automation SSH Hardening
Protocol 2
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PermitEmptyPasswords no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 60
MaxStartups 10:30:60
AllowGroups wheel
EOF

    # Test SSH configuration
    if sudo sshd -t; then
        log "✅ SSH configuration is valid" "$GREEN"
    else
        error_exit "Invalid SSH configuration"
    fi
}

# Step 13: Restart SSH service
restart_ssh_service() {
    log "🔄 Step 13: Restarting SSH service..." "$BLUE"

    action_log "Restarting SSH daemon..."
    if sudo systemctl restart ssh; then
        log "✅ SSH service restarted successfully" "$GREEN"
    else
        error_exit "Failed to restart SSH service"
    fi

    # Verify SSH service status
    if sudo systemctl is-active --quiet ssh; then
        log "✅ SSH service is active and running" "$GREEN"
    else
        error_exit "SSH service is not running properly"
    fi
}

# Step 16: Final verification and status report
final_verification() {
    log "🎯 Step 16: Final verification and status report..." "$BLUE"

    local selected_project="$1"

    log "📋 Final Status Report:" "$PURPLE"
    log "=====================================:" "$PURPLE"

    # Run final status check
    if check_pam_ssh_status "$selected_project"; then
        log "🎉 ALL CONFIGURATIONS COMPLETED SUCCESSFULLY!" "$GREEN"
        log "✅ PAM automation workflow completed without errors" "$GREEN"

        # Keep backups (timestamped approach)
        log "💾 Backups preserved in: $BACKUP_DIR" "$GREEN"

        return 0
    else
        warning_log "Some configurations may need attention. Check the status above."
        return 1
    fi
}

# Detect orphaned users (users not in CSV)
detect_orphaned_users() {
    log "🔍 Detecting orphaned users..." "$BLUE"

    # Get all users from CSV
    local csv_users=()
    while IFS=',' read -r project_group username password ssh_key; do
        [[ -n "$username" ]] && csv_users+=("$username")
    done <"$FULL_USER_LIST"

    # Get all wheel group members
    local wheel_users=()
    while IFS= read -r user; do
        wheel_users+=("$user")
    done < <(getent group wheel | cut -d: -f4 | tr ',' '\n' | grep -v '^$')

    # Find orphaned users
    local orphaned_users=()
    for wheel_user in "${wheel_users[@]}"; do
        local found=false
        for csv_user in "${csv_users[@]}"; do
            if [[ "$wheel_user" == "$csv_user" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == "false" ]]; then
            orphaned_users+=("$wheel_user")
        fi
    done

    if [[ ${#orphaned_users[@]} -gt 0 ]]; then
        warning_log "Found ${#orphaned_users[@]} orphaned users in wheel group:"
        for user in "${orphaned_users[@]}"; do
            log "  • $user" "$YELLOW"
        done

        echo -n "Remove orphaned users? (y/N): "
        read -r remove_orphaned
        if [[ "$remove_orphaned" =~ ^[Yy]$ ]]; then
            for user in "${orphaned_users[@]}"; do
                action_log "Removing orphaned user: $user"
                sudo userdel -r "$user" 2>/dev/null || warning_log "Could not remove $user"
                log "✅ Removed orphaned user: $user" "$GREEN"
            done
        fi
    else
        log "✅ No orphaned users found" "$GREEN"
    fi
}

# Enhanced safe rollback function
safe_rollback() {
    log "🔄 Starting safe rollback..." "$YELLOW"

    # Remove created users
    for user in "${CREATED_USERS[@]}"; do
        if id "$user" >/dev/null 2>&1; then
            log "🗑️  Removing created user: $user" "$YELLOW"
            sudo userdel -r "$user" 2>/dev/null || true
        fi
    done

    # Restore modified files
    for file in "${MODIFIED_FILES[@]}"; do
        if [[ -f "$BACKUP_DIR/$(basename "$file").backup" ]]; then
            log "🔄 Restoring file: $file" "$YELLOW"
            sudo cp "$BACKUP_DIR/$(basename "$file").backup" "$file"
        fi
    done

    # Remove created SSH directories
    for ssh_dir in "${CREATED_SSH_DIRS[@]}"; do
        if [[ -d "$ssh_dir" ]]; then
            log "🗑️  Removing SSH directory: $ssh_dir" "$YELLOW"
            sudo rm -rf "$ssh_dir"
        fi
    done

    log "✅ Rollback completed" "$GREEN"
}

# Main PAM creation workflow (action-only, no verification)
pam_creation_workflow() {
    local selected_project="$1"

    log "🚀 Starting PAM creation workflow for project: $selected_project" "$PURPLE"
    log "Workflow: 3 → 1 → 3 → 9 → 7 → 4* -> 5* -> 12 → 10 → 12 → 15 → 13 → 15 → 16" "$BLUE"

    # Create backup directory first
    create_backup_dir

    # Execute workflow steps
    check_pam_ssh_status "$selected_project"  # Step 3 (initial check)
    install_pam_packages                      # Step 1
    check_pam_ssh_status "$selected_project"  # Step 3 (post-install check)
    configure_wheel_group                     # Step 9
    configure_pam_policy                      # Step 7
    create_user_accounts "$selected_project"  # Step 4*
    configure_user_groups "$selected_project" # Step 5*
    setup_ssh_directories "$selected_project" # Step 12
    configure_ssh_keys "$selected_project"    # Step 10
    check_pam_ssh_status "$selected_project"  # Step 12 (verification)
    configure_ssh_daemon                      # Step 15
    restart_ssh_service                       # Step 13
    check_pam_ssh_status "$selected_project"  # Step 15 (verification)
    final_verification "$selected_project"    # Step 16

    log "🎉 PAM creation workflow completed!" "$GREEN"
}

# SSH hardening workflow (separate operation)
ssh_hardening_workflow() {
    log "🔒 Starting SSH hardening workflow..." "$PURPLE"

    create_backup_dir
    configure_ssh_daemon
    restart_ssh_service

    log "🎉 SSH hardening workflow completed!" "$GREEN"
}

# Display main menu
show_main_menu() {
    clear
    log "╔══════════════════════════════════════════════════════════════╗" "$PURPLE"
    log "║                    PAM Automation Agent V2                  ║" "$PURPLE"
    log "║                  Project-based CSV Approach                 ║" "$PURPLE"
    log "╚══════════════════════════════════════════════════════════════╝" "$PURPLE"
    log ""
    log "📋 Available Operations:" "$BLUE"
    log "1. 🎯 Automated PAM Creation (Project-based)" "$CYAN"
    log "2. 🔒 SSH Hardening Only" "$CYAN"
    log "3. 🔍 Status Check" "$CYAN"
    log "4. 🗑️  Orphaned User Management" "$CYAN"
    log "5. 📊 Generate Report" "$CYAN"
    log "6. ❌ Exit" "$CYAN"
    log ""
}

# Generate comprehensive report
generate_report() {
    log "📊 Generating comprehensive report..." "$BLUE"

    local report_file="pam_report_${TIMESTAMP}.md"

    cat >"$report_file" <<EOF
# PAM Automation Report
**Generated:** $(date)
**Script Version:** PAM Agent V2
**Execution ID:** $TIMESTAMP

## System Information
- **OS:** $(lsb_release -d | cut -f2-)
- **Kernel:** $(uname -r)
- **Hostname:** $(hostname)

## User Overview
$(cat "$FULL_USER_LIST" | wc -l) total users in CSV file

### Project Groups:
$(get_project_groups | while read project; do
        count=$(get_users_by_project "$project" | wc -l)
        echo "- **$project**: $count users"
    done)

## Current Status
### PAM Configuration
$(sudo ls -la /etc/pam.d/common-password | head -1)

### SSH Configuration  
$(sudo sshd -T | grep -E "(permitrootlogin|passwordauthentication|pubkeyauthentication)")

### Wheel Group Members
$(getent group wheel | cut -d: -f4 | tr ',' '\n' | sed 's/^/- /')

## Backups
- **Backup Directory:** $BACKUP_DIR

---
*Report generated by PAM Automation Agent V2*
EOF

    log "✅ Report generated: $report_file" "$GREEN"
    cat "$report_file"
}

# Main function
main() {

    log "🚀 PAM Automation Agent V2 Started" "$PURPLE"
    log "Timestamp: $(date)" "$BLUE"

    # Pre-flight validation
    pre_flight_validation

    # Validate CSV file
    validate_full_user_list

    while true; do
        show_main_menu
        echo -n "Select option (1-6): "
        read -r choice

        case $choice in
        1)
            log "🎯 Selected: Automated PAM Creation" "$GREEN"

            # Project selection
            selected_project=$(select_project_group)
            log "Selected project: $selected_project" "$GREEN"

            # Display users for confirmation
            display_selected_users "$selected_project"

            # Check if already complete
            if check_pam_ssh_status "$selected_project"; then
                log "✅ PAM setup is already complete for selected users!" "$GREEN"
                echo -n "Force re-run anyway? (y/N): "
                read -r force_rerun
                [[ ! "$force_rerun" =~ ^[Yy]$ ]] && continue
            fi

            # Run PAM creation workflow
            pam_creation_workflow "$selected_project"

            echo -n "Press Enter to continue..."
            read -r
            ;;
        2)
            log "🔒 Selected: SSH Hardening Only" "$GREEN"
            ssh_hardening_workflow
            echo -n "Press Enter to continue..."
            read -r
            ;;
        3)
            log "🔍 Selected: Status Check" "$GREEN"
            selected_project=$(select_project_group)
            check_pam_ssh_status "$selected_project"
            echo -n "Press Enter to continue..."
            read -r
            ;;
        4)
            log "🗑️  Selected: Orphaned User Management" "$GREEN"
            detect_orphaned_users
            echo -n "Press Enter to continue..."
            read -r
            ;;
        5)
            log "📊 Selected: Generate Report" "$GREEN"
            generate_report
            echo -n "Press Enter to continue..."
            read -r
            ;;
        6)
            log "👋 Goodbye!" "$GREEN"
            exit 0
            ;;
        *)
            warning_log "Invalid option. Please select 1-6."
            sleep 1
            ;;
        esac
    done
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
