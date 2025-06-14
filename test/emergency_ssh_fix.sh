#!/bin/bash

# Emergency SSH Configuration Fix Script
# This script will restore SSH service immediately

echo "🚨 Emergency SSH Configuration Fix - Starting..."

# Backup current broken config
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.broken_$(date +%Y%m%d_%H%M%S)

# Check if we have any backup files
echo "🔍 Checking for backup files..."
if ls /etc/ssh/sshd_config.backup_* 2>/dev/null; then
    echo "✅ Found backup files:"
    ls -la /etc/ssh/sshd_config.backup_*
    
    # Use the most recent backup
    latest_backup=$(ls -t /etc/ssh/sshd_config.backup_* | head -1)
    echo "🔄 Restoring from: $latest_backup"
    sudo cp "$latest_backup" /etc/ssh/sshd_config
else
    echo "⚠️ No backup found, creating clean minimal config..."
    
    # Create a minimal working SSH config
    sudo tee /etc/ssh/sshd_config > /dev/null << 'EOF'
# Minimal SSH Configuration - Emergency Recovery
Port 22
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

# Authentication
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PermitEmptyPasswords no
ChallengeResponseAuthentication no

# PAM and other settings
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server

# Security settings
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
MaxSessions 3
LoginGraceTime 60
EOF
fi

# Test the configuration
echo "🧪 Testing SSH configuration..."
if sudo sshd -t; then
    echo "✅ SSH configuration is valid"
    
    # Restart SSH service
    echo "🔄 Restarting SSH service..."
    if sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null; then
        echo "✅ SSH service restarted successfully"
        
        # Check service status
        if systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null; then
            echo "🎉 SSH service is now running!"
            echo "🔍 Current SSH service status:"
            systemctl status sshd 2>/dev/null || systemctl status ssh 2>/dev/null
        else
            echo "❌ SSH service is not running properly"
            systemctl status sshd 2>/dev/null || systemctl status ssh 2>/dev/null
        fi
    else
        echo "❌ Failed to restart SSH service"
        echo "📋 Checking journal logs:"
        journalctl -xeu ssh.service --no-pager -n 10
    fi
else
    echo "❌ SSH configuration is still invalid"
    echo "📋 Configuration errors:"
    sudo sshd -t
fi

echo "🔍 Current SSH configuration:"
echo "----------------------------------------"
sudo grep -E "^(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|UsePAM|X11Forwarding)" /etc/ssh/sshd_config
echo "----------------------------------------"
