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

    # # Check if running as root (should not be)
    # if [[ $EUID -eq 0 ]]; then
    #     error_exit "Do not run this script as root. Run with sudo privileges instead."
    # fi

    log "✅ Pre-flight validation passed" "$GREEN"
}

# Validate full user list CSV file
validate_full_user_list() {
    log "📄 Validating full user list CSV..." "$BLUE"
    
    # Temporarily disable strict mode for this function
    set +u

    if [[ ! -f "$FULL_USER_LIST" ]]; then
        warning_log "Full user list file not found: $FULL_USER_LIST"
        log "📝 Creating sample CSV file..." "$BLUE"
        exit 0
    fi

    if [[ ! -r "$FULL_USER_LIST" ]]; then
        error_exit "Cannot read full user list file: $FULL_USER_LIST"
    fi

    # Clean Windows line endings if they exist
    if command -v dos2unix >/dev/null 2>&1; then
        dos2unix "$FULL_USER_LIST" 2>/dev/null || true
    else
        # Use a safer sed approach that won't fail on some systems
        if [[ -w "$FULL_USER_LIST" ]]; then
            sed -i.bak 's/\r$//' "$FULL_USER_LIST" 2>/dev/null || {
                log "Skipping line ending cleanup (file not writable)" "$YELLOW"
            }
        fi
    fi

    # Validate CSV format - simplified and robust
    local line_count=0
    local valid_lines=0
    
    # Use a simpler approach without the problematic || condition
    # Add error handling around the file reading
    if ! {
        while IFS= read -r line; do
            ((line_count++))

            # Skip empty lines
            if [[ -z "$line" ]]; then
                continue
            fi

            # Parse CSV fields using a safer method
            IFS=',' read -ra fields <<< "$line"
            local column_count=${#fields[@]}
            
            # Check column count first
            if [[ "$column_count" -ne 4 ]]; then
                warning_log "Line $line_count has $column_count columns (expected 4): $line"
                continue
            fi

            # Extract fields with safe defaults
            local project_group="${fields[0]:-}"
            local username="${fields[1]:-}"
            local password="${fields[2]:-}"
            local ssh_key="${fields[3]:-}"

            # Validate required fields (project_group, username, password are required)
            if [[ -z "$project_group" || -z "$username" || -z "$password" ]]; then
                warning_log "Line $line_count: Missing required fields: $line"
                continue
            fi

            # Validate username format
            if ! [[ "$username" =~ ^[a-z][a-z0-9_-]*$ ]]; then
                warning_log "Line $line_count: Invalid username format '$username'"
                continue
            fi

            ((valid_lines++))

        done < "$FULL_USER_LIST"
    }; then
        error_exit "Failed to read CSV file during validation"
    fi
    
    if [[ "$valid_lines" -eq 0 ]]; then
        error_exit "No valid user entries found in CSV file"
    fi

    log "✅ Full user list validation passed ($valid_lines valid entries)" "$GREEN"
    
    # Re-enable strict mode
    set -u
}

# Get unique project groups from CSV
get_project_groups() {
    awk -F',' '{print $1}' "$FULL_USER_LIST" | sort -u | grep -v '^$'
}

# Get users for a specific project group
get_users_by_project() {
    local project_group="$1"
    # Use fixed string search instead of regex to avoid special character issues
    grep -F "${project_group}," "$FULL_USER_LIST" | grep "^${project_group}," || true
}

# Interactive project selection
select_project_group() {
    # Don't output the header here since it's interfering with function return
    local projects=()
    while IFS= read -r project; do
        # Skip empty lines and ensure we have a valid project name
        [[ -n "$project" ]] && projects+=("$project")
    done < <(get_project_groups)

    if [[ ${#projects[@]} -eq 0 ]]; then
        error_exit "No project groups found in $FULL_USER_LIST"
    fi

    # Display project options to stderr to avoid interfering with function return
    log "🎯 Available project groups:" "$PURPLE" >&2
    for i in "${!projects[@]}"; do
        local project="${projects[$i]}"
        local user_count=$(get_users_by_project "$project" | wc -l)
        log "$((i + 1)). $project ($user_count users)" "$CYAN" >&2
    done
    log "$((${#projects[@]} + 1)). All projects" "$CYAN" >&2

    # Get user selection
    local selected_project=""
    while [[ -z "$selected_project" ]]; do
        echo -n "Select project group (1-$((${#projects[@]} + 1))): " >&2
        read -r selection

        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le $((${#projects[@]} + 1)) ]]; then
            if [[ "$selection" -eq $((${#projects[@]} + 1)) ]]; then
                selected_project="ALL"
            else
                selected_project="${projects[$((selection - 1))]}"
            fi
        else
            log "⚠️  WARNING: Invalid selection. Please enter a number between 1 and $((${#projects[@]} + 1))" "$YELLOW" >&2
        fi
    done
    
    # Return the selected project properly to stdout
    echo "$selected_project"
}

# Generate local CSV files from filtered users
generate_local_csv_files() {
    local user_lines=("$@")
    
    log "💾 Generating local CSV files..." "$BLUE"
    
    # Create user_list.csv
    {
        for user_line in "${user_lines[@]}"; do
            IFS=',' read -r proj user pass ssh_key <<< "$user_line"
            echo "$user,$pass"
        done
    } > "user_list.csv"
    
    # Create ssh_key_list.csv  
    {
        for user_line in "${user_lines[@]}"; do
            IFS=',' read -r proj user pass ssh_key <<< "$user_line"
            [[ -n "$ssh_key" ]] && echo "$user,$ssh_key"
        done
    } > "ssh_key_list.csv"
    
    log "✅ Generated user_list.csv ($(wc -l < user_list.csv) users)" "$GREEN"
    log "✅ Generated ssh_key_list.csv ($(wc -l < ssh_key_list.csv) keys)" "$GREEN"
}

# Display users for filtering and confirmation
display_selected_users() {
    local project_group="$1"
    local user_data=""
    local users_array=()
    local filtered_users=()

    log "👥 Selected users for processing:" "$BLUE"

    if [[ "$project_group" == "ALL" ]]; then
        log "📋 All users from all projects:" "$PURPLE"
        user_data=$(cat "$FULL_USER_LIST")
    else
        log "📋 Users in project '$project_group':" "$PURPLE"
        user_data=$(get_users_by_project "$project_group")
    fi

    # Parse users into array for numbering
    local counter=1
    while IFS=',' read -r proj user pass ssh_key; do
        [[ -z "$user" ]] && continue
        users_array+=("$proj,$user,$pass,$ssh_key")
        local key_status="❌ No SSH key"
        [[ -n "$ssh_key" ]] && key_status="✅ SSH key present"
        log "  $counter. [$proj] $user - $key_status" "$CYAN"
        ((counter++))
    done <<< "$user_data"

    if [[ ${#users_array[@]} -eq 0 ]]; then
        error_exit "No users found for the selected project"
    fi

    # User filtering workflow
    log "" 
    log "🎯 Filter users out? (Enter user numbers to exclude, e.g., 1,3,5 or press Enter to keep all)" "$YELLOW"
    echo -n "Users to exclude: "
    read -r exclude_input

    if [[ -n "$exclude_input" ]]; then
        # Parse exclude numbers
        local exclude_array=()
        IFS=',' read -ra exclude_array <<< "$exclude_input"
        
        # Create filtered list (exclude specified users)
        for i in "${!users_array[@]}"; do
            local user_num=$((i + 1))
            local exclude_this=false
            
            for exclude_num in "${exclude_array[@]}"; do
                exclude_num=$(echo "$exclude_num" | tr -d ' ')
                if [[ "$user_num" -eq "$exclude_num" ]]; then
                    exclude_this=true
                    break
                fi
            done
            
            if [[ "$exclude_this" == "false" ]]; then
                filtered_users+=("${users_array[$i]}")
            fi
        done
        
        log "✅ Filtered out ${#exclude_array[@]} users" "$GREEN"
    else
        # Keep all users
        filtered_users=("${users_array[@]}")
        log "✅ Keeping all users" "$GREEN"
    fi

    # Display final selection
    log "" 
    log "📋 Final user selection (${#filtered_users[@]} users):" "$PURPLE"
    for user_line in "${filtered_users[@]}"; do
        IFS=',' read -r proj user pass ssh_key <<< "$user_line"
        local key_status="❌ No SSH key"
        [[ -n "$ssh_key" ]] && key_status="✅ SSH key present"
        log "  • [$proj] $user - $key_status" "$CYAN"
    done

    echo -n "Continue with these users? (y/N): "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "Operation cancelled by user" "$YELLOW"
        exit 0
    fi

    # Generate local CSV files
    generate_local_csv_files "${filtered_users[@]}"
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

# Step 4: Create user accounts from local CSV
create_user_accounts() {
    log "👤 Step 4: Creating user accounts..." "$BLUE"

    if [[ ! -f "user_list.csv" ]]; then
        warning_log "user_list.csv not found, skipping user creation"
        return 0
    fi

    while IFS=',' read -r username password; do
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
    done < "user_list.csv"
}

# Step 5: Configure user groups and permissions from local CSV
configure_user_groups() {
    log "👥 Step 5: Configuring user groups and permissions..." "$BLUE"

    if [[ ! -f "user_list.csv" ]]; then
        warning_log "user_list.csv not found, skipping group configuration"
        return 0
    fi

    while IFS=',' read -r username password; do
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
    done < "user_list.csv"
}

# Step 12: Setup SSH directories and permissions from local CSV
setup_ssh_directories() {
    log "🔑 Step 12: Setting up SSH directories..." "$BLUE"

    if [[ ! -f "user_list.csv" ]]; then
        warning_log "user_list.csv not found, skipping SSH directory setup"
        return 0
    fi

    while IFS=',' read -r username password; do
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
    done < "user_list.csv"
}

# Step 10: Configure SSH public keys from local CSV (FIXED: Override instead of append)
configure_ssh_keys() {
    log "🔐 Step 10: Configuring SSH public keys..." "$BLUE"

    if [[ ! -f "ssh_key_list.csv" ]]; then
        warning_log "ssh_key_list.csv not found, skipping SSH key configuration"
        return 0
    fi

    while IFS=',' read -r username ssh_key; do
        [[ -z "$username" || -z "$ssh_key" ]] && continue

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
    done < "ssh_key_list.csv"
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
    if sudo systemctl restart sshd; then
        log "✅ SSH service restarted successfully" "$GREEN"
    else
        error_exit "Failed to restart SSH service"
    fi

    # Verify SSH service status
    if sudo systemctl is-active --quiet sshd; then
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
    if [[ ${#CREATED_USERS[@]} -gt 0 ]]; then
        for user in "${CREATED_USERS[@]}"; do
            if id "$user" >/dev/null 2>&1; then
                log "🗑️  Removing created user: $user" "$YELLOW"
                sudo userdel -r "$user" 2>/dev/null || true
            fi
        done
    fi

    # Restore modified files
    if [[ ${#MODIFIED_FILES[@]} -gt 0 ]]; then
        for file in "${MODIFIED_FILES[@]}"; do
            if [[ -f "$BACKUP_DIR/$(basename "$file").backup" ]]; then
                log "🔄 Restoring file: $file" "$YELLOW"
                sudo cp "$BACKUP_DIR/$(basename "$file").backup" "$file"
            fi
        done
    fi

    # Remove created SSH directories
    if [[ ${#CREATED_SSH_DIRS[@]} -gt 0 ]]; then
        for ssh_dir in "${CREATED_SSH_DIRS[@]}"; do
            if [[ -d "$ssh_dir" ]]; then
                log "🗑️  Removing SSH directory: $ssh_dir" "$YELLOW"
                sudo rm -rf "$ssh_dir"
            fi
        done
    fi

    log "✅ Rollback completed" "$GREEN"
}

# Main PAM creation workflow using local CSV files
pam_creation_workflow() {
    log "🚀 Starting PAM creation workflow using local CSV files" "$PURPLE"
    log "Workflow: 3 → 1 → 3 → 9 → 7 → 4* -> 5* -> 12 → 10 → 12 → 15 → 13 → 15 → 16" "$BLUE"

    # Verify local CSV files exist
    if [[ ! -f "user_list.csv" ]]; then
        error_exit "user_list.csv not found! Please run project selection first."
    fi

    # Create backup directory first
    create_backup_dir

    # Execute workflow steps
    install_pam_packages                      # Step 1
    configure_wheel_group                     # Step 9
    configure_pam_policy                      # Step 7
    create_user_accounts                      # Step 4* (from user_list.csv)
    configure_user_groups                     # Step 5* (from user_list.csv)
    setup_ssh_directories                     # Step 12 (from user_list.csv)
    configure_ssh_keys                        # Step 10 (from ssh_key_list.csv)
    configure_ssh_daemon                      # Step 15
    restart_ssh_service                       # Step 13
    
    log "✅ PAM automation workflow completed using local CSV files!" "$GREEN"
    log "💾 Backups preserved in: $BACKUP_DIR" "$GREEN"
    log "📄 Local CSV files maintained: user_list.csv, ssh_key_list.csv" "$GREEN"

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
    log "6. 🧹 Cleanup Backup & CSV Files" "$CYAN"
    log "7. ❌ Exit" "$CYAN"
    log ""
}

# Generate essential PAM status report (display only)
generate_report() {
    log "📊 Generating PAM status report..." "$BLUE"
    log ""
    
    log "╔══════════════════════════════════════════════════════════════╗" "$PURPLE"
    log "║                    PAM AUTOMATION REPORT                    ║" "$PURPLE" 
    log "║                     $(date +'%Y-%m-%d %H:%M:%S')                      ║" "$PURPLE"
    log "╚══════════════════════════════════════════════════════════════╝" "$PURPLE"
    log ""

    # User Overview
    local total_users=$(grep -c "^[^,]*,[^,]*," "$FULL_USER_LIST" 2>/dev/null || echo "0")
    log "👥 USER OVERVIEW:" "$BLUE"
    log "  • Total users in CSV: $total_users" "$CYAN"
    
    # Project Groups
    log "  • Project groups:" "$CYAN"
    get_project_groups | while read project; do
        local count=$(get_users_by_project "$project" | wc -l)
        log "    - $project: $count users" "$CYAN"
    done
    log ""

    # Wheel Group Status
    log "🔐 WHEEL GROUP STATUS:" "$BLUE"
    if getent group wheel >/dev/null 2>&1; then
        local wheel_members=$(getent group wheel | cut -d: -f4 | tr ',' '\n' | grep -v '^$' | wc -l)
        log "  • Wheel group exists: ✅" "$GREEN"
        log "  • Members count: $wheel_members" "$CYAN"
        if [[ $wheel_members -gt 0 ]]; then
            log "  • Members:" "$CYAN"
            getent group wheel | cut -d: -f4 | tr ',' '\n' | grep -v '^$' | while read user; do
                log "    - $user" "$CYAN"
            done
        fi
    else
        log "  • Wheel group exists: ❌" "$RED"
    fi
    log ""

    # PAM Configuration Status
    log "🔒 PAM CONFIGURATION:" "$BLUE"
    if [[ -f "/etc/pam.d/common-password" ]]; then
        if grep -q "pam_pwquality.so" "/etc/pam.d/common-password"; then
            log "  • Password quality module: ✅ Configured" "$GREEN"
        else
            log "  • Password quality module: ❌ Not configured" "$RED"
        fi
    else
        log "  • PAM common-password: ❌ File not found" "$RED"
    fi
    
    if [[ -f "/etc/security/pwquality.conf" ]]; then
        log "  • Password quality config: ✅ Present" "$GREEN"
    else
        log "  • Password quality config: ❌ Missing" "$RED"
    fi
    log ""

    # SSH Configuration Status
    log "🌐 SSH CONFIGURATION:" "$BLUE"
    if sudo systemctl is-active --quiet ssh 2>/dev/null; then
        log "  • SSH service status: ✅ Active" "$GREEN"
    else
        log "  • SSH service status: ❌ Inactive" "$RED"
    fi
    
    if [[ -f "/etc/ssh/sshd_config" ]]; then
        if grep -q "AllowGroups wheel" "/etc/ssh/sshd_config"; then
            log "  • SSH wheel group restriction: ✅ Configured" "$GREEN"
        else
            log "  • SSH wheel group restriction: ❌ Not configured" "$YELLOW"
        fi
        
        if grep -q "PermitRootLogin no" "/etc/ssh/sshd_config"; then
            log "  • Root login disabled: ✅ Configured" "$GREEN"
        else
            log "  • Root login disabled: ❌ Not configured" "$YELLOW"
        fi
    fi
    log ""

    # Backup Information
    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
        log "💾 BACKUP INFORMATION:" "$BLUE"
        log "  • Backup directory: $BACKUP_DIR" "$CYAN"
        local backup_count=$(ls -1 "$BACKUP_DIR" 2>/dev/null | wc -l)
        log "  • Backup files: $backup_count" "$CYAN"
    fi
    
    log ""
    log "═══════════════════════════════════════════════════════════════" "$PURPLE"
}

# Cleanup function for backup and CSV files
cleanup_files() {
    log "🧹 Cleanup backup and CSV files..." "$BLUE"
    
    local files_to_remove=()
    local dirs_to_remove=()
    
    # Find backup directories
    if ls /tmp/pam_backup_* >/dev/null 2>&1; then
        for backup_dir in /tmp/pam_backup_*; do
            [[ -d "$backup_dir" ]] && dirs_to_remove+=("$backup_dir")
        done
    fi
    
    # Find CSV files
    [[ -f "full_user_list.csv" ]] && files_to_remove+=("full_user_list.csv")
    [[ -f "user_list.csv" ]] && files_to_remove+=("user_list.csv") 
    [[ -f "ssh_key_list.csv" ]] && files_to_remove+=("ssh_key_list.csv")
    
    # Find any backup CSV files
    [[ -f "full_user_list.csv.bak" ]] && files_to_remove+=("full_user_list.csv.bak")
    
    if [[ ${#dirs_to_remove[@]} -eq 0 && ${#files_to_remove[@]} -eq 0 ]]; then
        log "✅ No cleanup needed - no backup or CSV files found" "$GREEN"
        return 0
    fi
    
    log "📋 Files and directories to be removed:" "$YELLOW"
    
    # Show backup directories
    if [[ ${#dirs_to_remove[@]} -gt 0 ]]; then
        log "  📁 Backup directories:" "$CYAN"
        for dir in "${dirs_to_remove[@]}"; do
            local file_count=$(ls -1 "$dir" 2>/dev/null | wc -l)
            log "    • $dir ($file_count files)" "$CYAN"
        done
    fi
    
    # Show CSV files
    if [[ ${#files_to_remove[@]} -gt 0 ]]; then
        log "  📄 CSV files:" "$CYAN"
        for file in "${files_to_remove[@]}"; do
            local size=$(ls -lh "$file" 2>/dev/null | awk '{print $5}' || echo "unknown")
            log "    • $file ($size)" "$CYAN"
        done
    fi
    
    echo -n "⚠️  Proceed with cleanup? This action cannot be undone! (y/N): "
    read -r confirm_cleanup
    
    if [[ "$confirm_cleanup" =~ ^[Yy]$ ]]; then
        # Remove backup directories
        for dir in "${dirs_to_remove[@]}"; do
            if rm -rf "$dir" 2>/dev/null; then
                log "✅ Removed backup directory: $dir" "$GREEN"
            else
                warning_log "Failed to remove: $dir"
            fi
        done
        
        # Remove CSV files
        for file in "${files_to_remove[@]}"; do
            if rm -f "$file" 2>/dev/null; then
                log "✅ Removed file: $file" "$GREEN"
            else
                warning_log "Failed to remove: $file"
            fi
        done
        
        log "🎉 Cleanup completed!" "$GREEN"
    else
        log "Cleanup cancelled by user" "$YELLOW"
    fi
}

# Main function
main() {

    log "🚀 PAM Automation Agent V2 Started" "$PURPLE"
    log "Timestamp: $(date)" "$BLUE"

    # Pre-flight validation
    pre_flight_validation

    # Validate CSV file
    validate_full_user_list

    log "✅ Full user list validation completed" "$GREEN"

    while true; do
        show_main_menu
        echo -n "Select option (1-7): "
        read -r choice

        case $choice in
        1)
            log "🎯 Selected: Automated PAM Creation" "$GREEN"

            # Project selection
            selected_project=$(select_project_group)
            log "Selected project: $selected_project" "$GREEN"

            # Display users for confirmation with filtering
            display_selected_users "$selected_project"

            # Check if already complete
            if check_pam_ssh_status "$selected_project"; then
                log "✅ PAM setup is already complete for selected users!" "$GREEN"
                echo -n "Force re-run anyway? (y/N): "
                read -r force_rerun
                [[ ! "$force_rerun" =~ ^[Yy]$ ]] && continue
            fi

            # Run PAM creation workflow (using generated local CSV files)
            pam_creation_workflow

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
            log "🧹 Selected: Cleanup Backup & CSV Files" "$GREEN"
            cleanup_files
            echo -n "Press Enter to continue..."
            read -r
            ;;
        7)
            log "👋 Goodbye!" "$GREEN"
            exit 0
            ;;
        *)
            warning_log "Invalid option. Please select 1-7."
            sleep 1
            ;;
        esac
    done
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
