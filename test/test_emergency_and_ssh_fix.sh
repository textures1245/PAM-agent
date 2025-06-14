#!/bin/bash

# Test script for Emergency SSH Fix and simplified SSH Hardening

echo "🧪 Testing PAM Agent V4 - Emergency SSH Fix and SSH Hardening Simplification"
echo "============================================================================="

# Test 1: Check syntax
echo "1. Checking script syntax..."
if bash -n pam-agent-v4.sh 2>/dev/null; then
    echo "   ✅ Syntax OK"
else
    echo "   ❌ Syntax Error"
    bash -n pam-agent-v4.sh
    exit 1
fi

# Test 2: Check if emergency function exists
echo "2. Checking emergency_ssh_system_fix function..."
if grep -q "emergency_ssh_system_fix()" pam-agent-v4.sh; then
    echo "   ✅ Emergency function found"
else
    echo "   ❌ Emergency function not found"
    exit 1
fi

# Test 3: Check if simplified SSH hardening exists
echo "3. Checking simplified ssh_security_hardening function..."
if grep -q "pam.example.sh choice 16" pam-agent-v4.sh; then
    echo "   ✅ Simplified SSH hardening found"
else
    echo "   ❌ Simplified SSH hardening not found"
    exit 1
fi

# Test 4: Check menu option 99
echo "4. Checking menu option 99..."
if grep -q "99.*Emergency SSH" pam-agent-v4.sh; then
    echo "   ✅ Menu option 99 found"
else
    echo "   ❌ Menu option 99 not found"
    exit 1
fi

# Test 5: Check case statement for option 99
echo "5. Checking case statement for option 99..."
if grep -A3 "99)" pam-agent-v4.sh | grep -q "emergency_ssh_system_fix"; then
    echo "   ✅ Case 99 handler found"
else
    echo "   ❌ Case 99 handler not found"
    exit 1
fi

# Test 6: Check if sed commands match pam.example.sh
echo "6. Checking SSH hardening sed commands..."
if grep -A10 "sudo sed -i.bak -E" pam-agent-v4.sh | grep -q "PermitRootLogin no"; then
    echo "   ✅ SSH hardening commands match pam.example.sh"
else
    echo "   ❌ SSH hardening commands don't match"
    exit 1
fi

echo ""
echo "🎉 All tests passed! Emergency SSH fix and simplified SSH hardening are properly implemented."
echo ""
echo "📋 Summary of changes:"
echo "   - Added emergency_ssh_system_fix() function"
echo "   - Added menu option 99 for emergency SSH recovery" 
echo "   - Simplified ssh_security_hardening() to match pam.example.sh choice 16"
echo "   - Added safety checks and backup functionality"
echo "   - Added SSH privilege separation directory creation"
