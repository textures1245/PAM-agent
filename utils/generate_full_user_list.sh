#!/bin/bash

# Migration Helper Script: V1 to V2 CSV Conversion
# Converts separate user_list.csv and ssh_key_list.csv to unified full_user_list.csv

echo "🔄 PAM Agent V1 to V2 Migration Helper"
echo "======================================"

# Check if old files exist
if [[ ! -f "../etc/user_list.csv" ]]; then
    echo "❌ Error: ../etc/user_list.csv not found"
    exit 1
fi

if [[ ! -f "../etc/ssh_key_list.csv" ]]; then
    echo "⚠️  Warning: ../etc/ssh_key_list.csv not found, will create entries without SSH keys"
fi

echo "📄 Converting CSV files..."

# Create header for new file
echo "project_group,username,password,ssh_public_key" > full_user_list.csv

# Read user list and create associative array for SSH keys
declare -A ssh_keys

# Load SSH keys if file exists
if [[ -f "../etc/ssh_key_list.csv" ]]; then
    while IFS=',' read -r username ssh_key; do
        # Skip empty lines
        [[ -z "$username" ]] && continue
        ssh_keys["$username"]="$ssh_key"
    done < "../etc/ssh_key_list.csv"
fi

# Convert user list
while IFS=',' read -r username password; do
    # Skip empty lines
    [[ -z "$username" ]] && continue
    
    # Get SSH key for user (if exists)
    ssh_key="${ssh_keys[$username]:-}"
    
    # Default project group name
    project_group="project_default"
    
    # Add to new CSV
    echo "$project_group,$username,$password,$ssh_key" >> full_user_list.csv
done < "../etc/user_list.csv"

echo "✅ Migration completed!"
echo ""
echo "📋 Summary:"
echo "- New file created: full_user_list.csv"
echo "- Users converted: $(tail -n +2 full_user_list.csv | wc -l)"
echo "- Default project group: project_default"
echo ""
echo "📝 Next steps:"
echo "1. Review and edit full_user_list.csv to customize project groups"
echo "2. Test with: ./pam-agent-v2.sh (option 3 - Status Check)"
echo "3. Run automation with: ./pam-agent-v2.sh (option 1)"
echo ""
echo "🔍 Preview of converted file:"
echo "------------------------------"
head -5 full_user_list.csv
echo ""

# Offer to show the full file
echo -n "Show full converted file? (y/N): "
read -r show_full
if [[ "$show_full" =~ ^[Yy]$ ]]; then
    echo ""
    echo "📄 Full converted file content:"
    echo "==============================="
    cat full_user_list.csv
fi
