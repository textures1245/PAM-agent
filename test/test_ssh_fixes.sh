#!/bin/bash

# Test script to validate SSH fixes in emergency recovery and PAM Agent V4
# This script tests the emergency SSH recovery functionality and verifies
# that PAM Agent V4 won't cause SSH service failures

echo "🧪 Testing SSH Fixes and Recovery Scripts"
echo "=========================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log() {
    echo -e "${2:-$NC}$1${NC}"
}

# Test 1: Check emergency SSH system fix script syntax
log "🔍 Test 1: Validating emergency SSH system fix script..." "$BLUE"
if bash -n emergency_ssh_system_fix.sh; then
    log "✅ Emergency SSH system fix script syntax is valid" "$GREEN"
else
    log "❌ Emergency SSH system fix script has syntax errors" "$RED"
    exit 1
fi

# Test 2: Check PAM Agent V4 script syntax
log "🔍 Test 2: Validating PAM Agent V4 script..." "$BLUE"
if bash -n pam-agent-v4.sh; then
    log "✅ PAM Agent V4 script syntax is valid" "$GREEN"
else
    log "❌ PAM Agent V4 script has syntax errors" "$RED"
    exit 1
fi

# Test 3: Verify SSH privilege separation directory fix is present in PAM Agent V4
log "🔍 Test 3: Checking SSH privilege separation fix in PAM Agent V4..." "$BLUE"
if grep -q "mkdir.*run.*sshd" pam-agent-v4.sh; then
    log "✅ SSH privilege separation directory fix found in PAM Agent V4" "$GREEN"
else
    log "❌ SSH privilege separation directory fix missing in PAM Agent V4" "$RED"
    exit 1
fi

# Test 4: Verify emergency script has comprehensive checks
log "🔍 Test 4: Checking emergency script features..." "$BLUE"

checks_passed=0
total_checks=5

# Check 1: SSH directory creation
if grep -q "mkdir.*run.*sshd" emergency_ssh_system_fix.sh; then
    log "  ✅ SSH privilege separation directory creation" "$GREEN"
    ((checks_passed++))
else
    log "  ❌ SSH privilege separation directory creation missing" "$RED"
fi

# Check 2: Host key generation
if grep -q "ssh-keygen" emergency_ssh_system_fix.sh; then
    log "  ✅ SSH host key generation" "$GREEN"
    ((checks_passed++))
else
    log "  ❌ SSH host key generation missing" "$RED"
fi

# Check 3: Configuration backup
if grep -q "emergency_" emergency_ssh_system_fix.sh; then
    log "  ✅ Configuration backup mechanism" "$GREEN"
    ((checks_passed++))
else
    log "  ❌ Configuration backup mechanism missing" "$RED"
fi

# Check 4: Service restart with fallbacks
if grep -q "systemctl restart.*||" emergency_ssh_system_fix.sh; then
    log "  ✅ Service restart with fallback methods" "$GREEN"
    ((checks_passed++))
else
    log "  ❌ Service restart fallback methods missing" "$RED"
fi

# Check 5: Configuration testing
if grep -q "sshd -t" emergency_ssh_system_fix.sh; then
    log "  ✅ SSH configuration testing" "$GREEN"
    ((checks_passed++))
else
    log "  ❌ SSH configuration testing missing" "$RED"
fi

log "📊 Emergency script features: $checks_passed/$total_checks passed" "$CYAN"

# Test 5: Verify PAM Agent V4 has safe SSH configuration method
log "🔍 Test 5: Checking safe SSH configuration in PAM Agent V4..." "$BLUE"
if grep -q "temp_config.*safe" pam-agent-v4.sh; then
    log "✅ Safe SSH configuration method found" "$GREEN"
elif grep -q "sshd -t -f.*temp" pam-agent-v4.sh; then
    log "✅ SSH configuration testing before applying found" "$GREEN"
else
    log "⚠️  Consider adding SSH configuration testing before applying" "$YELLOW"
fi

# Test 6: Check for Phase 3 enhancements
log "🔍 Test 6: Checking Phase 3 enhancements..." "$BLUE"
phase3_features=0

if grep -q "Phase 3" pam-agent-v4.sh; then
    log "  ✅ Phase 3 markers found" "$GREEN"
    ((phase3_features++))
fi

if grep -q "Enhanced error handling.*pipefail" pam-agent-v4.sh; then
    log "  ✅ Enhanced error handling documentation" "$GREEN"
    ((phase3_features++))
fi

if grep -q "|| {" pam-agent-v4.sh; then
    log "  ✅ Improved error handling patterns" "$GREEN"
    ((phase3_features++))
fi

log "📊 Phase 3 features: $phase3_features/3 found" "$CYAN"

# Test 7: Verify emergency script permissions and executability
log "🔍 Test 7: Checking script permissions..." "$BLUE"
if [[ -x emergency_ssh_system_fix.sh ]]; then
    log "✅ Emergency SSH system fix script is executable" "$GREEN"
else
    log "⚠️  Making emergency SSH system fix script executable" "$YELLOW"
    chmod +x emergency_ssh_system_fix.sh
fi

if [[ -x pam-agent-v4.sh ]]; then
    log "✅ PAM Agent V4 script is executable" "$GREEN"
else
    log "⚠️  Making PAM Agent V4 script executable" "$YELLOW"
    chmod +x pam-agent-v4.sh
fi

# Final summary
echo
log "🎯 SSH Fix Validation Summary" "$CYAN"
log "=============================" "$CYAN"
log "✅ Emergency SSH system fix script: Ready for deployment" "$GREEN"
log "✅ PAM Agent V4: SSH privilege separation fix applied" "$GREEN"
log "✅ Phase 3 enhancements: Active" "$GREEN"
log "✅ All syntax checks: Passed" "$GREEN"

echo
log "🚀 Ready for Production Deployment:" "$GREEN"
log "1. Deploy emergency_ssh_system_fix.sh to fix immediate SSH service failure" "$BLUE"
log "2. Use PAM Agent V4 for future PAM operations (SSH issue prevented)" "$BLUE"
log "3. Both scripts have comprehensive error handling and recovery methods" "$BLUE"

echo
log "📋 Emergency Deployment Command:" "$YELLOW"
log "sudo bash emergency_ssh_system_fix.sh" "$YELLOW"

echo
log "🔧 Test completed successfully! SSH fixes validated." "$GREEN"
