#!/bin/bash

# Emergency SSH Service Recovery Script - System Fix
# This script fixes the missing# Step 5: Set correc    # Step 7: Restart SSH service
    echo "🔄 Restarting SSH service..."
    
    # Try different service names and restart methods
    if sudo systemctl restart sshd 2>/dev/null; then
        service_name="sshd"
    elif sudo systemctl restart ssh 2>/dev/null; then
        service_name="ssh"
    elif sudo service sshd restart 2>/dev/null; then
        service_name="sshd"
        echo "✅ SSH service (sshd) restarted using service command"
    elif sudo service ssh restart 2>/dev/null; then
        service_name="ssh"
        echo "✅ SSH service (ssh) restarted using service command"
    else
        echo "❌ Failed to restart SSH service"
        echo "📋 Checking what went wrong:"
        journalctl -xeu ssh.service --no-pager -n 10 2>/dev/null || true
        journalctl -xeu sshd.service --no-pager -n 10 2>/dev/null || true
        echo "📋 Trying manual start:"
        sudo /usr/sbin/sshd -D &
        sleep 2
        if pgrep sshd >/dev/null; then
            echo "✅ SSH started manually"
            service_name="manual"
        else
            exit 1
        fi
    fi
    
    echo "✅ SSH service ($service_name) restarted successfully"
    
    # Step 8: Verify service is running"🔧 Setting correct permissions..."
sudo chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null || true
sudo chmod 644 /etc/ssh/ssh_host_*_key.pub 2>/dev/null || true
sudo chmod 644 /etc/ssh/sshd_config
sudo chown root:root /etc/ssh/sshd_config
sudo chown root:root /etc/ssh/ssh_host_* 2>/dev/null || true
echo "✅ File permissions set correctly"

# Step 6: Test the configurationshd directory issue

echo "🚨 Emergency SSH System Fix - Starting..."

# Step 1: Create the missing SSH privilege separation directory
echo "🔧 Creating missing SSH privilege separation directory..."
sudo mkdir -p /run/sshd
sudo chown root:root /run/sshd
sudo chmod 755 /run/sshd
echo "✅ Created /run/sshd directory with proper permissions"

# Also ensure the parent directory has proper permissions
sudo chmod 755 /run 2>/dev/null || true
echo "✅ Verified /run directory permissions"

# Step 2: Fix any SSH configuration issues
echo "🔧 Fixing SSH configuration..."

# Backup current config
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.emergency_$(date +%Y%m%d_%H%M%S)

# Create a clean, working SSH configuration
sudo tee /etc/ssh/sshd_config > /dev/null << 'EOF'
# Emergency SSH Configuration - System Recovery
Port 22
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

# Host keys
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

# Privilege separation
UsePrivilegeSeparation yes

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

# Security settings
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
MaxSessions 3
LoginGraceTime 60
UseDNS no

# Subsystem
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

# Step 3: Generate host keys if missing
echo "🔧 Checking SSH host keys..."
sudo mkdir -p /etc/ssh 2>/dev/null || true

if [[ ! -f /etc/ssh/ssh_host_rsa_key ]] || [[ ! -f /etc/ssh/ssh_host_ecdsa_key ]] || [[ ! -f /etc/ssh/ssh_host_ed25519_key ]]; then
    echo "🔑 Generating missing SSH host keys..."
    
    # Generate specific keys if missing
    [[ ! -f /etc/ssh/ssh_host_rsa_key ]] && sudo ssh-keygen -t rsa -b 4096 -f /etc/ssh/ssh_host_rsa_key -N "" 2>/dev/null
    [[ ! -f /etc/ssh/ssh_host_ecdsa_key ]] && sudo ssh-keygen -t ecdsa -f /etc/ssh/ssh_host_ecdsa_key -N "" 2>/dev/null
    [[ ! -f /etc/ssh/ssh_host_ed25519_key ]] && sudo ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" 2>/dev/null
    
    # Or use ssh-keygen -A as fallback
    sudo ssh-keygen -A 2>/dev/null || true
    
    echo "✅ SSH host keys generated/verified"
else
    echo "✅ SSH host keys exist"
fi

# Step 4: Check and fix SELinux context if SELinux is enabled
echo "🔧 Checking SELinux context for SSH..."
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
    echo "📋 SELinux is enabled, fixing SSH contexts..."
    sudo restorecon -R -v /etc/ssh/ 2>/dev/null || true
    sudo restorecon -R -v /run/sshd 2>/dev/null || true
    echo "✅ SELinux contexts restored"
else
    echo "✅ SELinux not enabled or not available"
fi

# Step 5: Set correct permissions
echo "🔧 Setting correct permissions..."
sudo chmod 600 /etc/ssh/ssh_host_*_key
sudo chmod 644 /etc/ssh/ssh_host_*_key.pub
sudo chmod 644 /etc/ssh/sshd_config

# Step 6: Test the configuration
echo "🧪 Testing SSH configuration..."
if sudo sshd -t; then
    echo "✅ SSH configuration is valid"
    
    # Step 7: Restart SSH service
    echo "🔄 Restarting SSH service..."
    
    # Try different service names
    if sudo systemctl restart sshd 2>/dev/null; then
        service_name="sshd"
    elif sudo systemctl restart ssh 2>/dev/null; then
        service_name="ssh"
    else
        echo "❌ Failed to restart SSH service"
        echo "📋 Checking what went wrong:"
        journalctl -xeu ssh.service --no-pager -n 10
        journalctl -xeu sshd.service --no-pager -n 10
        exit 1
    fi
    
    echo "✅ SSH service ($service_name) restarted successfully"
    
    # Step 8: Verify service is running
    sleep 3
    if systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null || pgrep sshd >/dev/null; then
        echo "🎉 SSH service is now running properly!"
        echo "🔍 Service status:"
        systemctl status $service_name --no-pager -l 2>/dev/null || ps aux | grep sshd | grep -v grep
        
        echo ""
        echo "🔐 Current SSH configuration:"
        echo "----------------------------------------"
        sudo grep -E "^(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|UsePAM|X11Forwarding)" /etc/ssh/sshd_config 2>/dev/null || echo "Could not read SSH config"
        echo "----------------------------------------"
        
        echo ""
        echo "✅ SSH Recovery Complete!"
        echo "🔒 Root login is now disabled"
        echo "🔑 Password and key authentication enabled"
        echo "⚠️  Make sure you have non-root user access before logging out!"
        
        # Additional verification
        echo ""
        echo "🔧 System verification:"
        echo "- SSH process: $(pgrep sshd | wc -l) running"
        echo "- Listening on port 22: $(ss -tlnp | grep :22 | wc -l) sockets"
        echo "- Config file size: $(wc -c < /etc/ssh/sshd_config) bytes"
        
    else
        echo "❌ SSH service is not running properly"
        systemctl status $service_name --no-pager -l 2>/dev/null || echo "Cannot get service status"
        echo "📋 Checking logs:"
        journalctl -xeu $service_name --no-pager -n 20 2>/dev/null || echo "Cannot get journal logs"
        echo "📋 Process check:"
        ps aux | grep sshd | grep -v grep || echo "No SSH processes found"
    fi
    
else
    echo "❌ SSH configuration is still invalid"
    echo "📋 Configuration errors:"
    sudo sshd -t
    exit 1
fi

echo ""
echo "🔍 Final system check:"
echo "- SSH directory: $(ls -ld /run/sshd 2>/dev/null || echo 'Missing')"
echo "- SSH service: $(systemctl is-active sshd ssh 2>/dev/null | head -1)"
echo "- Config file: $(ls -l /etc/ssh/sshd_config)"

echo ""
echo "🎯 Next Steps:"
echo "1. Test SSH connection from another session"
echo "2. Fix the PAM Agent V4 script to prevent this issue"
echo "3. Verify you can login with non-root user"
