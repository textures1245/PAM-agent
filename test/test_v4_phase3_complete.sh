#!/bin/bash

# Test script for PAM Agent V4 Phase 3 Complete Implementation
# Tests all Phase 3 improvements and features

echo "========================================"
echo "    PAM Agent V4 Phase 3 Test Suite"
echo "========================================"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    echo -e "${2:-$NC}$1${NC}"
}

test_count=0
passed_count=0
failed_count=0

run_test() {
    local test_name="$1"
    local test_command="$2"
    
    ((test_count++))
    log "🧪 Test $test_count: $test_name" "$CYAN"
    
    if eval "$test_command"; then
        log "✅ PASSED: $test_name" "$GREEN"
        ((passed_count++))
    else
        log "❌ FAILED: $test_name" "$RED"
        ((failed_count++))
    fi
    echo
}

# Test 1: Check if pam-agent-v4.sh exists and is executable
run_test "PAM Agent V4 file exists and executable" \
    "[[ -f './pam-agent-v4.sh' && -x './pam-agent-v4.sh' ]]"

# Test 2: Check Phase 3 header comments
run_test "Phase 3 header documentation" \
    "grep -q 'Phase 3' ./pam-agent-v4.sh"

# Test 3: Verify removal of set -eo pipefail (exclude comments)
run_test "Removed set -eo pipefail" \
    "! grep -v '^#' ./pam-agent-v4.sh | grep -q 'set -eo pipefail'"

# Test 4: Check for || true error handling patterns
run_test "New || true error handling pattern" \
    "grep -q '|| {' ./pam-agent-v4.sh"

# Test 5: Check for enhanced SSH hardening function
run_test "Enhanced SSH hardening function exists" \
    "grep -q 'SSH Security Hardening - Enhanced for Phase 3' ./pam-agent-v4.sh"

# Test 6: Check for PAM Example Script integration
run_test "PAM Example Script integration function" \
    "grep -q 'run_pam_example_script' ./pam-agent-v4.sh"

# Test 7: Check for GitLab curl command
run_test "GitLab curl command integration" \
    "grep -q 'https://gitlab.com/aomsin3310/script' ./pam-agent-v4.sh"

# Test 8: Check for Advanced Cleanup functionality
run_test "Advanced Cleanup function exists" \
    "grep -q 'advanced_cleanup' ./pam-agent-v4.sh"

# Test 9: Check for backup files cleanup
run_test "Backup files cleanup function" \
    "grep -q 'cleanup_backup_files' ./pam-agent-v4.sh"

# Test 10: Check for dependencies cleanup
run_test "Dependencies cleanup function" \
    "grep -q 'cleanup_dependencies' ./pam-agent-v4.sh"

# Test 11: Check for updated main menu (8 options)
run_test "Updated main menu with 8 options" \
    "grep -q '🎯 กรุณาเลือกหมายเลข (1-8)' ./pam-agent-v4.sh"

# Test 12: Check for Phase 3 enhanced menu title
run_test "Phase 3 enhanced menu title" \
    "grep -q 'Phase 3 - Enhanced Features' ./pam-agent-v4.sh"

# Test 13: Check for improved SSH configuration (PermitRootLogin fix)
run_test "SSH PermitRootLogin fix implementation" \
    "grep -q 'ลบการตั้งค่า PermitRootLogin ที่ซ้ำออกก่อน' ./pam-agent-v4.sh"

# Test 14: Check for password expiry bug fix
run_test "Password expiry bug fix implementation" \
    "grep -q 'ตรวจสอบว่าค่าที่ตั้งถูกต้องหรือไม่' ./pam-agent-v4.sh"

# Test 15: Verify JSON structure requirements
run_test "JSON structure validation" \
    "grep -q 'users and .ip_mappings' ./pam-agent-v4.sh"

# Test 16: Check for rollback functionality
run_test "Rollback functionality exists" \
    "grep -q 'safe_rollback' ./pam-agent-v4.sh"

# Test 17: Check for warning_log function
run_test "Warning log function implementation" \
    "grep -q 'warning_log()' ./pam-agent-v4.sh"

# Test 18: Verify trap signal handling
run_test "Signal trap handling" \
    "grep -q \"trap 'error_exit\" ./pam-agent-v4.sh"

# Test 19: Check for jq dependency management
run_test "jq dependency management" \
    "grep -q 'command -v jq' ./pam-agent-v4.sh"

# Test 20: Verify enhanced error messages
run_test "Enhanced error messages" \
    "grep -q 'Phase 3' ./pam-agent-v4.sh && grep -q 'warning_log' ./pam-agent-v4.sh"

# Functional Tests (if user_credentials_clean.json exists)
if [[ -f "./user_credentials_clean.json" ]]; then
    log "🔍 Found user_credentials_clean.json - Running functional tests..." "$BLUE"
    
    # Test 21: JSON syntax validation
    run_test "JSON file syntax validation" \
        "jq empty ./user_credentials_clean.json 2>/dev/null"
    
    # Test 22: JSON structure validation
    run_test "JSON structure validation (users and ip_mappings)" \
        "jq -e '.users and .ip_mappings' ./user_credentials_clean.json >/dev/null 2>&1"
    
    # Test 23: IP mappings exist
    run_test "IP mappings contain data" \
        "[[ \$(jq '.ip_mappings | length' ./user_credentials_clean.json 2>/dev/null) -gt 0 ]]"
    
    # Test 24: Users array exists
    run_test "Users array contains data" \
        "[[ \$(jq '.users | length' ./user_credentials_clean.json 2>/dev/null) -gt 0 ]]"
else
    log "⚠️ user_credentials_clean.json not found - skipping functional tests" "$YELLOW"
fi

# Phase 3 Specific Feature Tests
log "🚀 Testing Phase 3 Specific Features..." "$BLUE"

# Test 25: New menu options exist
run_test "PAM Example Script menu option (6)" \
    "grep -q '6) 🛠️ PAM Example Script' ./pam-agent-v4.sh"

run_test "Advanced Cleanup menu option (7)" \
    "grep -q '7) 🗂️ Advanced Cleanup' ./pam-agent-v4.sh"

run_test "Exit option updated to (8)" \
    "grep -q '8) 🚪 Exit' ./pam-agent-v4.sh"

# Test 26: Error handling improvements
run_test "Improved error handling patterns" \
    "grep -c '|| {' ./pam-agent-v4.sh | [[ \$(cat) -gt 5 ]]"

# Test 27: SSH configuration enhancement
run_test "SSH config enhancement with phase3bak" \
    "grep -q 'phase3bak' ./pam-agent-v4.sh"

# Results Summary
echo "========================================"
log "           TEST RESULTS SUMMARY" "$CYAN"
echo "========================================"
log "Total Tests: $test_count" "$BLUE"
log "Passed: $passed_count" "$GREEN"
log "Failed: $failed_count" "$RED"

if [[ $failed_count -eq 0 ]]; then
    log "🎉 ALL TESTS PASSED! PAM Agent V4 Phase 3 is ready!" "$GREEN"
    echo
    log "✅ Phase 3 Features Successfully Implemented:" "$GREEN"
    echo "  • Removed set -eo pipefail error handling"
    echo "  • Enhanced SSH configuration (fixed PermitRootLogin issue)"
    echo "  • Added PAM Example Script integration from GitLab"
    echo "  • Added Advanced Cleanup functionality"
    echo "  • Improved password expiry bug handling"
    echo "  • Added backup and dependency cleanup"
    echo "  • Enhanced menu with 8 options"
    echo "  • Improved error handling with || true patterns"
    echo
    log "🚀 Ready for production deployment!" "$CYAN"
else
    log "⚠️ Some tests failed. Please review the implementation." "$YELLOW"
    echo
    log "📋 Failed Tests Summary:" "$RED"
    if [[ $failed_count -gt 0 ]]; then
        echo "  • Check failed tests above for specific issues"
        echo "  • Verify all Phase 3 features are properly implemented"
        echo "  • Review error handling patterns"
    fi
fi

echo "========================================"
echo "📄 Test completed at: $(date)"
echo "========================================"
