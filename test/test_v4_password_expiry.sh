#!/bin/bash

# Test PAM Agent V4 Password Expiry Feature
# Test various input scenarios for password expiry days

echo "=== Testing PAM Agent V4 Password Expiry Feature ==="

# Copy the current JSON file to test with
cp user_credentials_clean.json user_credentials_clean_test.json

# Test the get_password_expiry_days function
echo "1. Testing empty input (should set to 9999)"
echo "" | timeout 10s bash -c '
    source pam-agent-v4.sh
    get_password_expiry_days
    echo "Result: $PASSWORD_EXPIRY_DAYS"
'

echo -e "\n2. Testing 0 input (should set to 9999)"
echo "0" | timeout 10s bash -c '
    source pam-agent-v4.sh
    get_password_expiry_days
    echo "Result: $PASSWORD_EXPIRY_DAYS"
'

echo -e "\n3. Testing negative input (should set to 9999)"
echo "-30" | timeout 10s bash -c '
    source pam-agent-v4.sh
    get_password_expiry_days
    echo "Result: $PASSWORD_EXPIRY_DAYS"
'

echo -e "\n4. Testing valid positive input (should set to input value)"
echo "90" | timeout 10s bash -c '
    source pam-agent-v4.sh
    get_password_expiry_days
    echo "Result: $PASSWORD_EXPIRY_DAYS"
'

echo -e "\n5. Testing another valid input"
echo "365" | timeout 10s bash -c '
    source pam-agent-v4.sh
    get_password_expiry_days
    echo "Result: $PASSWORD_EXPIRY_DAYS"
'

# Clean up
rm -f user_credentials_clean_test.json

echo -e "\n=== Test completed ==="
