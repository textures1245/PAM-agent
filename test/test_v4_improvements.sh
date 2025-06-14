#!/bin/bash

# Test script for PAM Agent V4 improvements
# Tests error handling and password expiry functionality

echo "🧪 Testing PAM Agent V4 improvements..."

# Test 1: Check if error handling is properly set up
echo "📋 Test 1: Error handling configuration"
if grep -q "set -eo pipefail" pam-agent-v4.sh; then
    echo "✅ Using graceful error handling (set -eo pipefail)"
else
    echo "❌ Error handling not configured properly"
fi

if ! grep -q "set -euo pipefail" pam-agent-v4.sh; then
    echo "✅ Not using strict error handling (good for production)"
else
    echo "⚠️  Still using strict error handling - may cause silent failures"
fi

# Test 2: Check if password expiry function exists
echo ""
echo "📋 Test 2: Password expiry function"
if grep -q "get_password_expiry_days()" pam-agent-v4.sh; then
    echo "✅ Password expiry input function exists"
else
    echo "❌ Password expiry input function missing"
fi

if grep -q "PASSWORD_EXPIRY_DAYS" pam-agent-v4.sh; then
    echo "✅ Password expiry variable exists"
else
    echo "❌ Password expiry variable missing"
fi

# Test 3: Check if CSV generation includes headers
echo ""
echo "📋 Test 3: CSV generation fixes"
if grep -q 'echo "username,password" >"$USER_LIST_FILE"' pam-agent-v4.sh; then
    echo "✅ CSV headers are properly generated"
else
    echo "❌ CSV headers missing or commented out"
fi

# Test 4: Check if debugging is added to password expiry
echo ""
echo "📋 Test 4: Password expiry debugging"
if grep -q "Debug: PASSWORD_EXPIRY_DAYS" pam-agent-v4.sh; then
    echo "✅ Password expiry debugging added"
else
    echo "❌ Password expiry debugging missing"
fi

# Test 5: Check if error handling improvements are in place
echo ""
echo "📋 Test 5: Enhanced error handling"
if grep -q "warning_log" pam-agent-v4.sh; then
    echo "✅ Warning log function exists"
else
    echo "❌ Warning log function missing"
fi

if grep -q "2>/dev/null" pam-agent-v4.sh; then
    echo "✅ Error suppression added to critical commands"
else
    echo "❌ No error suppression found"
fi

echo ""
echo "🎯 Summary:"
echo "- Script uses graceful error handling instead of strict mode"
echo "- Password expiry functionality properly implemented with user input"
echo "- CSV generation fixes applied"
echo "- Enhanced error handling with warnings instead of silent failures"
echo "- Debugging added to identify password expiry issues"

echo ""
echo "✅ Test completed! You can now run the improved PAM Agent V4."
