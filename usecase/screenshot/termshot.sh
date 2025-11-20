
# Termshot Utility Functions for CIS PAM Capture Agent
# Purpose: SSH operations and termshot management
# Author: PAM Automation Team
# Version: 1.0

#!/bin/bash

# This script is meant to be sourced, not executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "⚠️  This script should be sourced, not executed directly."
    echo "Usage: source termshot.sh"
    exit 1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Global variables
TERMSHOT_VERSION="v0.6.0"
TERMSHOT_DOWNLOAD_BASE="https://github.com/homeport/termshot/releases/download"
SSH_CONTROL_PATH="/tmp/ssh_mux_%h_%p_%r"
SSH_TIMEOUT=10

# Logging function
ts_log() {
    echo -e "${2:-$NC}${1}${NC}"
}

# Error handling
ts_error() {
    ts_log "❌ ERROR: $1" "$RED"
    return 1
}

# Function: Detect remote OS architecture
# Usage: detect_remote_arch <ssh_user> <ssh_host> <ssh_key>
detect_remote_arch() {
    local ssh_user="$1"
    local ssh_host="$2"
    local ssh_key="${3:-}"
    
    local ssh_cmd="ssh -o ConnectTimeout=$SSH_TIMEOUT -o StrictHostKeyChecking=no"
    if [[ -n "$ssh_key" ]]; then
        ssh_cmd="$ssh_cmd -i $ssh_key"
    fi
    
    local arch
    arch=$($ssh_cmd "${ssh_user}@${ssh_host}" "uname -m" 2>/dev/null)
    
    case "$arch" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            ts_log "⚠️  Unknown architecture: $arch, defaulting to amd64" "$YELLOW"
            echo "amd64"
            ;;
    esac
}

# Function: Install termshot on remote VM
# Usage: install_termshot_on_remote <ssh_user> <ssh_host> <ssh_key>
install_termshot_on_remote() {
    local ssh_user="$1"
    local ssh_host="$2"
    local ssh_key="${3:-}"
    
    ts_log "  📦 Installing termshot on $ssh_host..." "$CYAN"
    
    # Build SSH command
    local ssh_cmd="ssh -o ConnectTimeout=$SSH_TIMEOUT -o StrictHostKeyChecking=no"
    if [[ -n "$ssh_key" ]]; then
        ssh_cmd="$ssh_cmd -i $ssh_key"
    fi
    
    # Check if termshot already installed
    if $ssh_cmd "${ssh_user}@${ssh_host}" "which termshot" &>/dev/null; then
        ts_log "    ℹ️  termshot already installed, skipping" "$YELLOW"
        return 0
    fi
    
    # Install using official install script
    ts_log "    📥 Downloading and installing termshot..." "$BLUE"
    
    $ssh_cmd "${ssh_user}@${ssh_host}" bash << 'EOF'
        set -e
        # Use official install script
        curl -s https://raw.githubusercontent.com/homeport/termshot/main/hack/download.sh | bash
        
        # Verify installation
        if command -v termshot &>/dev/null; then
            echo "✅ termshot installed successfully"
        else
            echo "ERROR: termshot installation failed" >&2
            exit 1
        fi
EOF
    
    if [[ $? -eq 0 ]]; then
        ts_log "    ✅ termshot installed successfully" "$GREEN"
        return 0
    else
        ts_error "Failed to install termshot on $ssh_host"
        return 1
    fi
}

# Function: Uninstall termshot from remote VM
# Usage: uninstall_termshot_on_remote <ssh_user> <ssh_host> <ssh_key>
uninstall_termshot_on_remote() {
    local ssh_user="$1"
    local ssh_host="$2"
    local ssh_key="${3:-}"
    
    ts_log "  🗑️  Uninstalling termshot from $ssh_host..." "$CYAN"
    
    local ssh_cmd="ssh -o ConnectTimeout=$SSH_TIMEOUT -o StrictHostKeyChecking=no"
    if [[ -n "$ssh_key" ]]; then
        ssh_cmd="$ssh_cmd -i $ssh_key"
    fi
    
    $ssh_cmd "${ssh_user}@${ssh_host}" "sudo rm -f /usr/local/bin/termshot" 2>/dev/null || true
    
    ts_log "    ✅ termshot uninstalled" "$GREEN"
}

# Function: Execute command on remote via SSH
# Usage: ssh_execute_cmd <ssh_user> <ssh_host> <ssh_key> <command>
ssh_execute_cmd() {
    local ssh_user="$1"
    local ssh_host="$2"
    local ssh_key="${3:-}"
    local command="$4"
    
    local ssh_cmd="ssh -o ConnectTimeout=$SSH_TIMEOUT -o StrictHostKeyChecking=no"
    if [[ -n "$ssh_key" ]]; then
        ssh_cmd="$ssh_cmd -i $ssh_key"
    fi
    
    $ssh_cmd "${ssh_user}@${ssh_host}" "$command" 2>&1
    return $?
}

# Function: Get VM hostname
# Usage: get_vm_hostname <ssh_user> <ssh_host> <ssh_key>
get_vm_hostname() {
    local ssh_user="$1"
    local ssh_host="$2"
    local ssh_key="${3:-}"
    
    local hostname
    
    hostname=$(ssh_execute_cmd "$ssh_user" "$ssh_host" "$ssh_key" "hostname -s" 2>/dev/null)
    
    if [[ -z "$hostname" ]]; then
        hostname="$ssh_host"
    fi
    
    echo "$hostname"
}

# Function: Create remote folder for screenshots
# Usage: create_remote_folder <ssh_user> <ssh_host> <ssh_key> <folder_name>
create_remote_folder() {
    local ssh_user="$1"
    local ssh_host="$2"
    local ssh_key="${3:-}"
    local folder_name="$4"
    
    ssh_execute_cmd "$ssh_user" "$ssh_host" "$ssh_key" "mkdir -p '$folder_name'" &>/dev/null
    
    if [[ $? -eq 0 ]]; then
        return 0
    else
        ts_error "Failed to create folder: $folder_name on $ssh_host"
        return 1
    fi
}

# Function: Capture screenshot remotely
# Usage: capture_screenshot_remote <ssh_user> <ssh_host> <ssh_key> <folder> <command> <output_filename>
capture_screenshot_remote() {
    local ssh_user="$1"
    local ssh_host="$2"
    local ssh_key="${3:-}"
    local folder="$4"
    local command="$5"
    local output_file="$6"
    
    local ssh_cmd="ssh -o ConnectTimeout=$SSH_TIMEOUT -o StrictHostKeyChecking=no"
    if [[ -n "$ssh_key" ]]; then
        ssh_cmd="$ssh_cmd -i $ssh_key"
    fi
    
    # Properly escape the command for remote execution
    local escaped_cmd=$(printf '%q' "$command")
    
    # Execute command and capture with termshot
    # Use \$ to prevent local expansion of $ variables
    $ssh_cmd "${ssh_user}@${ssh_host}" bash << REMOTE_EOF
        cd ~
        # Get the hostname and current user
        HOSTNAME=\$(hostname -s 2>/dev/null || hostname)
        CURRENT_USER=\$(whoami)
        
        # Create a temp file with command prompt and output
        {
            printf '%s@%s: ~/#' "\${CURRENT_USER}" "\${HOSTNAME}"
            printf ' %s\n' ${escaped_cmd}
            eval ${escaped_cmd}
        } > /tmp/cmd_output_\$\$.txt 2>&1
        termshot --filename "${folder}/${output_file}" --raw-read /tmp/cmd_output_\$\$.txt &>/dev/null || echo "WARNING: termshot failed"
        rm -f /tmp/cmd_output_\$\$.txt
REMOTE_EOF
    
    if [[ $? -eq 0 ]]; then
        return 0
    else
        ts_log "    ⚠️  Warning: Failed to capture $output_file" "$YELLOW"
        return 1
    fi
}

# Function: SCP folder from remote to local
# Usage: scp_folder_to_local <ssh_user> <ssh_host> <ssh_key> <remote_folder> <local_dest>
scp_folder_to_local() {
    local ssh_user="$1"
    local ssh_host="$2"
    local ssh_key="${3:-}"
    local remote_folder="$4"
    local local_dest="${5:-.}"
    
    ts_log "  📥 Downloading screenshots from $ssh_host..." "$CYAN"
    
    local scp_cmd="scp -r -o ConnectTimeout=$SSH_TIMEOUT -o StrictHostKeyChecking=no"
    if [[ -n "$ssh_key" ]]; then
        scp_cmd="$scp_cmd -i $ssh_key"
    fi
    
    $scp_cmd "${ssh_user}@${ssh_host}:${remote_folder}" "$local_dest" 2>&1 | grep -v "^scp:" || true
    
    if [[ $? -eq 0 ]]; then
        ts_log "    ✅ Screenshots downloaded successfully" "$GREEN"
        return 0
    else
        ts_error "Failed to download screenshots from $ssh_host"
        return 1
    fi
}

# Function: Cleanup remote folder
# Usage: cleanup_remote_folder <ssh_user> <ssh_host> <ssh_key> <folder_path>
cleanup_remote_folder() {
    local ssh_user="$1"
    local ssh_host="$2"
    local ssh_key="${3:-}"
    local folder_path="$4"
    
    ssh_execute_cmd "$ssh_user" "$ssh_host" "$ssh_key" "rm -rf '$folder_path'" &>/dev/null
    
    if [[ $? -eq 0 ]]; then
        return 0
    else
        ts_log "    ⚠️  Warning: Failed to cleanup remote folder" "$YELLOW"
        return 1
    fi
}

# Function: Test SSH connection
# Usage: test_ssh_connection <ssh_user> <ssh_host> <ssh_key>
test_ssh_connection() {
    local ssh_user="$1"
    local ssh_host="$2"
    local ssh_key="${3:-}"
    
    local ssh_cmd="ssh -o ConnectTimeout=$SSH_TIMEOUT -o StrictHostKeyChecking=no"
    if [[ -n "$ssh_key" ]]; then
        ssh_cmd="$ssh_cmd -i $ssh_key"
    fi
    
    $ssh_cmd "${ssh_user}@${ssh_host}" "echo 'connected'" &>/dev/null
    return $?
}

# Export functions for use in other scripts
export -f ts_log
export -f ts_error
export -f detect_remote_arch
export -f install_termshot_on_remote
export -f uninstall_termshot_on_remote
export -f ssh_execute_cmd
export -f get_vm_hostname
export -f create_remote_folder
export -f capture_screenshot_remote
export -f scp_folder_to_local
export -f cleanup_remote_folder
export -f test_ssh_connection

ts_log "✅ termshot.sh functions loaded successfully" "$GREEN"
