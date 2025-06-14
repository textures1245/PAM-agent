#!/bin/bash

# Extract Clean User Credentials Script V2 - Header-Based Dynamic Detection
# Based on proven V1 logic with added dynamic column detection for resilience
# Extracts user credentials directly from raw CSV files and generates clean JSON format
# Eliminates data duplication by using username as primary key
#
# Input: raw_user_list.csv + raw_user_credentail.csv (raw source files)
# Output: user_credentials_clean.json (username-based structure with IP arrays)
#
# Features:
# - NEW: Header-Based Dynamic Column Detection with fallback to defaults
# - Direct extraction from raw data (no intermediate files)
# - Robust CSV parsing handling quoted fields and special characters
# - Eliminates duplicate user credentials
# - Groups IPs per user in arrays
# - Creates reverse IP mappings for easy lookup
# - Adds metadata for tracking
# - Validates data integrity
#
# Version: 2.0 - Header-Based Dynamic Detection
# Created: 2025-06-10

# set -euo pipefail

# Input and output files
USER_LIST_FILE="./raw_user_list.csv"
USER_CREDS_FILE="./raw_user_credentail.csv"
OUTPUT_JSON="./user_credentials_clean.json"
TEMP_DIR="/tmp/clean_users_$$"

# Column position variables (will be detected dynamically with fallbacks)
IP_COLUMN=3       # Default fallback: column 4 (index 3) - IP Private
USERNAME_COLUMN=5 # Default fallback: column 6 (index 5) - Username
PASSWORD_COLUMN=6 # Default fallback: column 7 (index 6) - Password
SSH_KEY_COLUMN=7  # Default fallback: column 8 (index 7) - SSH Public Key

# Detection flags
IP_DETECTED=false
CREDS_DETECTED=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging function
log() {
    local message="$1"
    local color="${2:-$NC}"
    echo -e "${color}${message}${NC}"
}

# Error handling
error_exit() {
    log "❌ ERROR: $1" "$RED"
    cleanup_temp
    exit 1
}

# Cleanup temporary files
cleanup_temp() {
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}

# Check if jq is installed
check_dependencies() {
    if ! command -v jq >/dev/null 2>&1; then
        log "📦 Installing jq..." "$YELLOW"
        if command -v brew >/dev/null 2>&1; then
            brew install jq
        elif command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update && sudo apt-get install -y jq
        else
            error_exit "jq is required but not installed. Please install jq manually."
        fi
    fi
    log "✅ jq is available" "$GREEN"
}

# Validate input files
validate_input() {
    log "📄 Validating input files..." "$BLUE"

    # Check raw_user_list.csv
    if [[ ! -f "$USER_LIST_FILE" ]]; then
        error_exit "User list file not found: $USER_LIST_FILE"
    fi

    if [[ ! -r "$USER_LIST_FILE" ]]; then
        error_exit "Cannot read user list file: $USER_LIST_FILE"
    fi

    # Check raw_user_credentail.csv
    if [[ ! -f "$USER_CREDS_FILE" ]]; then
        error_exit "User credentials file not found: $USER_CREDS_FILE"
    fi

    if [[ ! -r "$USER_CREDS_FILE" ]]; then
        error_exit "Cannot read user credentials file: $USER_CREDS_FILE"
    fi

    local user_list_lines=$(wc -l <"$USER_LIST_FILE")
    local user_creds_lines=$(wc -l <"$USER_CREDS_FILE")

    if [[ $user_list_lines -lt 3 ]]; then
        error_exit "User list file contains insufficient data (need at least header + 1 data row)"
    fi

    if [[ $user_creds_lines -lt 2 ]]; then
        error_exit "User credentials file contains insufficient data (need at least header + 1 data row)"
    fi

    log "✅ Input validation passed" "$GREEN"
    log "   - User list: $((user_list_lines - 2)) data rows" "$CYAN"
    log "   - User credentials: $((user_creds_lines - 1)) data rows" "$CYAN"
}

# NEW: Dynamic column detection for user_list.csv
detect_user_list_columns() {
    log "🔍 Detecting user_list.csv column structure..." "$BLUE"

    # Read first header line using safe method
    local header_line=$(sed -n '1p' "$USER_LIST_FILE")

    # Simple column detection: look for "IP Private"
    local column_index=0
    local temp_field=""
    local in_quotes=false

    for ((i = 0; i < ${#header_line}; i++)); do
        char="${header_line:$i:1}"

        if [[ "$char" == '"' ]]; then
            in_quotes=$((!in_quotes))
        elif [[ "$char" == ',' ]] && [[ "$in_quotes" == "false" ]]; then
            # End of field, check if it matches IP Private pattern
            clean_field=$(echo "$temp_field" | sed 's/^"//;s/"$//;s/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ "$clean_field" =~ [Ii][Pp].*[Pp]rivate ]] || [[ "$clean_field" == "IP Private" ]]; then
                IP_COLUMN=$column_index
                IP_DETECTED=true
                log "✅ Found IP Private column at position $column_index" "$GREEN"
                break
            fi
            temp_field=""
            ((column_index++))
        else
            temp_field+="$char"
        fi
    done

    # Check the last field
    if [[ "$IP_DETECTED" == "false" ]]; then
        clean_field=$(echo "$temp_field" | sed 's/^"//;s/"$//;s/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ "$clean_field" =~ [Ii][Pp].*[Pp]rivate ]] || [[ "$clean_field" == "IP Private" ]]; then
            IP_COLUMN=$column_index
            IP_DETECTED=true
            log "✅ Found IP Private column at position $column_index" "$GREEN"
        fi
    fi

    if [[ "$IP_DETECTED" == "false" ]]; then
        log "⚠️  IP Private column not detected, using default position $IP_COLUMN" "$YELLOW"
    fi
}

# NEW: Dynamic column detection for user_credentail.csv
detect_user_creds_columns() {
    log "🔍 Detecting user_credentail.csv column structure..." "$BLUE"

    # Use the robust CSV parser to handle the header with potential line breaks
    local temp_header="/tmp/creds_header_$$"
    sed -n '1p' "$USER_CREDS_FILE" >"$temp_header"

    # Parse using our proven CSV parser
    local temp_fields="/tmp/header_fields_$$"
    parse_csv_line "$(cat "$temp_header")" >"$temp_fields"

    local username_found=false
    local password_found=false
    local ssh_key_found=false
    local column_index=0

    # Check each parsed field
    while IFS= read -r field; do
        clean_field=$(clean_field "$field")

        # Check for Username
        if [[ "$clean_field" =~ [Uu]sername ]] && [[ "$username_found" == "false" ]]; then
            USERNAME_COLUMN=$column_index
            username_found=true
            log "✅ Found Username column at position $column_index" "$GREEN"
        fi

        # Check for Password
        if [[ "$clean_field" =~ [Pp]assword ]] && [[ "$password_found" == "false" ]]; then
            PASSWORD_COLUMN=$column_index
            password_found=true
            log "✅ Found Password column at position $column_index" "$GREEN"
        fi

        # Check for SSH Key
        if [[ "$clean_field" =~ [Ss][Ss][Hh].*[Kk]ey ]] && [[ "$ssh_key_found" == "false" ]]; then
            SSH_KEY_COLUMN=$column_index
            ssh_key_found=true
            log "✅ Found SSH Key column at position $column_index" "$GREEN"
        fi

        ((column_index++))
    done <"$temp_fields"

    rm -f "$temp_fields" "$temp_header"

    if [[ "$username_found" == "true" ]] && [[ "$password_found" == "true" ]] && [[ "$ssh_key_found" == "true" ]]; then
        CREDS_DETECTED=true
        log "✅ All credential columns detected successfully" "$GREEN"
    else
        log "⚠️  Some credential columns not detected, using defaults:" "$YELLOW"
        [[ "$username_found" == "false" ]] && log "   - Username: position $USERNAME_COLUMN (default)" "$YELLOW"
        [[ "$password_found" == "false" ]] && log "   - Password: position $PASSWORD_COLUMN (default)" "$YELLOW"
        [[ "$ssh_key_found" == "false" ]] && log "   - SSH Key: position $SSH_KEY_COLUMN (default)" "$YELLOW"
    fi
}

# Function to clean CSV field (remove quotes and trim spaces)
clean_field() {
    echo "$1" | sed 's/^"//;s/"$//;s/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Function to escape JSON string
escape_json() {
    echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g; s/\r/\\r/g; s/\t/\\t/g'
}

# Function to validate IP address format
is_valid_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to properly parse CSV with quoted fields - compatible version
parse_csv_line() {
    local line="$1"
    local field=""
    local in_quotes=false
    local i=0

    # Clear any existing temp file
    local temp_fields="/tmp/csv_fields_$$"
    >"$temp_fields"

    while [ $i -lt ${#line} ]; do
        char="${line:$i:1}"

        if [ "$char" = '"' ]; then
            if $in_quotes; then
                # Check if next char is also quote (escaped quote)
                if [ $((i + 1)) -lt ${#line} ] && [ "${line:$((i + 1)):1}" = '"' ]; then
                    field="${field}\""
                    i=$((i + 1))
                else
                    in_quotes=false
                fi
            else
                in_quotes=true
            fi
        elif [ "$char" = ',' ] && ! $in_quotes; then
            echo "$field" >>"$temp_fields"
            field=""
        else
            field="${field}${char}"
        fi
        i=$((i + 1))
    done

    # Add the last field
    echo "$field" >>"$temp_fields"

    # Output fields
    cat "$temp_fields"
    rm -f "$temp_fields"
}

# Parse raw CSV files and extract data directly to JSON-ready format
parse_raw_data() {
    log "📊 Parsing raw CSV data directly..." "$CYAN"

    mkdir -p "$TEMP_DIR"

    # Create temporary files for processing
    local users_data="$TEMP_DIR/users_data.tmp"
    local ip_data="$TEMP_DIR/ip_data.tmp"

    # Clear temp files
    >"$users_data"
    >"$ip_data"

    # Extract header line from user_list.csv (line 2 contains user names)
    local USER_HEADER=$(sed -n '2p' "$USER_LIST_FILE")

    log "🔍 Extracting IP addresses and user mappings..." "$BLUE"

    local processed_ips=0
    local total_user_ip_pairs=0

    # Process each data row in user_list.csv (starting from line 3)
    tail -n +3 "$USER_LIST_FILE" | while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*$ ]]; then
            continue
        fi

        # Parse CSV line properly handling quotes
        temp_fields="/tmp/fields_$$"
        parse_csv_line "$line" >"$temp_fields"

        # Read fields into array
        FIELDS=()
        while IFS= read -r field; do
            FIELDS+=("$field")
        done <"$temp_fields"
        rm -f "$temp_fields"

        # Extract IP address using detected column position
        if [[ ${#FIELDS[@]} -gt $IP_COLUMN ]]; then
            IP=$(clean_field "${FIELDS[$IP_COLUMN]}")

            # Skip if IP is empty, contains dash, or is not a valid IP format
            if [[ -z "$IP" ]] || [[ "$IP" == "-" ]] || ! is_valid_ip "$IP"; then
                continue
            fi

            echo "  Processing IP: $IP" >&2
            ((processed_ips++))

            # Parse user header to match with user columns
            temp_headers="/tmp/headers_$$"
            parse_csv_line "$USER_HEADER" >"$temp_headers"

            USER_HEADERS=()
            while IFS= read -r header; do
                USER_HEADERS+=("$header")
            done <"$temp_headers"
            rm -f "$temp_headers"

            # Start from column 12 (index 11) where user data begins
            for i in {11..30}; do
                if [[ $i -lt ${#FIELDS[@]} ]] && [[ $i -lt ${#USER_HEADERS[@]} ]]; then
                    user_value=$(clean_field "${FIELDS[$i]}")
                    user_header=$(clean_field "${USER_HEADERS[$i]}")

                    # Check if this column contains a user name pattern and has a value
                    if [[ "$user_header" =~ User[[:space:]]+([a-zA-Z]+) ]] && [[ -n "$user_value" ]] && [[ "$user_value" != "" ]]; then
                        username="${BASH_REMATCH[1]}"
                        echo "    Found user: $username with value: $user_value" >&2

                        # Look up credentials for this username using proper CSV parsing
                        found_credentials=false
                        while IFS= read -r cred_line; do
                            if [[ -z "$cred_line" ]]; then
                                continue
                            fi

                            # Parse credentials line
                            temp_creds="/tmp/creds_$$"
                            parse_csv_line "$cred_line" >"$temp_creds"

                            CRED_FIELDS=()
                            while IFS= read -r cred_field; do
                                CRED_FIELDS+=("$cred_field")
                            done <"$temp_creds"
                            rm -f "$temp_creds"

                            if [[ ${#CRED_FIELDS[@]} -gt $USERNAME_COLUMN ]] && [[ ${#CRED_FIELDS[@]} -gt $PASSWORD_COLUMN ]] && [[ ${#CRED_FIELDS[@]} -gt $SSH_KEY_COLUMN ]]; then
                                cred_username=$(clean_field "${CRED_FIELDS[$USERNAME_COLUMN]}")

                                # Check if this line contains our target username
                                if [[ "$cred_username" == "$username" ]]; then
                                    password=$(clean_field "${CRED_FIELDS[$PASSWORD_COLUMN]}")
                                    ssh_key=$(clean_field "${CRED_FIELDS[$SSH_KEY_COLUMN]}")

                                    # Store user data (with pipe separator to avoid comma issues)
                                    echo "$username|$password|$ssh_key|$IP" >>"$users_data"
                                    echo "$IP|$username" >>"$ip_data"

                                    echo "      Added: $IP,$username" >&2
                                    ((total_user_ip_pairs++))
                                    found_credentials=true
                                    break
                                fi
                            fi
                        done < <(grep -i ",$username," "$USER_CREDS_FILE")

                        # If no match found, show warning
                        if [[ "$found_credentials" == "false" ]]; then
                            echo "      Warning: No credentials found for user: $username" >&2
                        fi
                    fi
                fi
           
            done
        fi
    done

    log "📈 Raw data extraction completed:" "$BLUE"
    log "   - Processed IPs: $processed_ips" "$CYAN"
    log "   - Total user-IP pairs: $total_user_ip_pairs" "$CYAN"

    # Now aggregate the data to eliminate duplicates
    log "🔄 Aggregating and deduplicating data..." "$CYAN"

    # Create final aggregated files
    local final_users="$TEMP_DIR/final_users.tmp"
    local final_ips="$TEMP_DIR/final_ips.tmp"
    local user_order="$TEMP_DIR/user_order.tmp"

    >"$final_users"
    >"$final_ips"
    >"$user_order"

    # First pass: collect unique usernames in the order they appear (preserve left-to-right order from CSV)
    if [[ -f "$users_data" ]]; then
        while IFS='|' read -r username password ssh_key ip; do
            if ! grep -q "^$username$" "$user_order" 2>/dev/null; then
                echo "$username" >>"$user_order"
            fi
        done <"$users_data"
    fi

    # Aggregate users data (group IPs by username) - preserving original order
    if [[ -f "$users_data" ]]; then
        while IFS= read -r ordered_username; do
            # Find all entries for this user and aggregate IPs
            user_ips=""
            user_password=""
            user_ssh_key=""

            while IFS='|' read -r username password ssh_key ip; do
                if [[ "$username" == "$ordered_username" ]]; then
                    if [[ -z "$user_password" ]]; then
                        user_password="$password"
                        user_ssh_key="$ssh_key"
                    fi

                    # Add IP if not already in the list
                    if [[ -z "$user_ips" ]]; then
                        user_ips="$ip"
                    elif [[ "$user_ips" != *"$ip"* ]]; then
                        user_ips="$user_ips,$ip"
                    fi
                fi
            done <"$users_data"

            # Write aggregated user data
            if [[ -n "$user_password" ]]; then
                echo "$ordered_username|$user_password|$user_ssh_key|$user_ips" >>"$final_users"
            fi

        done <"$user_order"
    fi

    # Aggregate IP data (group users by IP) - preserving original order
    if [[ -f "$ip_data" ]]; then
        # Get unique IPs in order they appear
        local ip_order="$TEMP_DIR/ip_order.tmp"
        >"$ip_order"

        while IFS='|' read -r ip username; do
            if ! grep -q "^$ip$" "$ip_order" 2>/dev/null; then
                echo "$ip" >>"$ip_order"
            fi
        done <"$ip_data"

        # For each IP, collect users in the order they appear (following CSV column order)
        while IFS= read -r ordered_ip; do
            ip_users=""

            # Use the user_order file to maintain original user sequence
            while IFS= read -r ordered_username; do
                if grep -q "^$ordered_ip|$ordered_username$" "$ip_data" 2>/dev/null; then
                    if [[ -z "$ip_users" ]]; then
                        ip_users="$ordered_username"
                    else
                        ip_users="$ip_users,$ordered_username"
                    fi
                fi
            done <"$user_order"

            # Write aggregated IP data
            if [[ -n "$ip_users" ]]; then
                echo "$ordered_ip|$ip_users" >>"$final_ips"
            fi

        done <"$ip_order"
        rm -f "$ip_order"
    fi

    # Remove duplicates within each record (but preserve order)
    if [[ -f "$final_users" ]]; then
        while IFS='|' read -r username password ssh_key ips; do
            # Remove duplicate IPs but preserve order (no sorting)
            local unique_ips=""
            IFS=',' read -ra IP_ARRAY <<<"$ips"
            for ip in "${IP_ARRAY[@]}"; do
                if [[ -z "$unique_ips" ]]; then
                    unique_ips="$ip"
                elif [[ "$unique_ips" != *"$ip"* ]]; then
                    unique_ips="$unique_ips,$ip"
                fi
            done
            echo "$username|$password|$ssh_key|$unique_ips"
        done <"$final_users" >"$final_users.clean"
        mv "$final_users.clean" "$final_users"
    fi

    if [[ -f "$final_ips" ]]; then
        while IFS='|' read -r ip users; do
            # Remove duplicate users but preserve order (no sorting)
            local unique_users=""
            IFS=',' read -ra USER_ARRAY <<<"$users"
            for user in "${USER_ARRAY[@]}"; do
                if [[ -z "$unique_users" ]]; then
                    unique_users="$user"
                elif [[ "$unique_users" != *"$user"* ]]; then
                    unique_users="$unique_users,$user"
                fi
            done
            echo "$ip|$unique_users"
        done <"$final_ips" >"$final_ips.clean"
        mv "$final_ips.clean" "$final_ips"
    fi

    local unique_users=$(wc -l <"$final_users" 2>/dev/null || echo "0")
    local unique_ips=$(wc -l <"$final_ips" 2>/dev/null || echo "0")

    log "📊 Final data summary:" "$BLUE"
    log "   - Unique users: $unique_users" "$CYAN"
    log "   - Unique IPs: $unique_ips" "$CYAN"
    log "   - Duplicate reduction: $((total_user_ip_pairs - unique_users)) user records consolidated" "$GREEN"
}

# Generate JSON output from aggregated data
generate_json() {
    log "🔄 Generating clean JSON structure..." "$CYAN"

    local final_users="$TEMP_DIR/final_users.tmp"
    local final_ips="$TEMP_DIR/final_ips.tmp"
    local current_date=$(date +"%Y-%m-%d")

    # Start JSON structure
    {
        echo "{"
        echo "  \"metadata\": {"
        echo "    \"generated_at\": \"$current_date\","
        echo "    \"extraction_method\": \"Header-Based Dynamic Detection V2\","
        echo "    \"source_files\": [\"raw_user_list.csv\", \"raw_user_credentail.csv\"],"
        echo "    \"format_version\": \"2.0\","
        echo "    \"column_detection\": {"
        echo "      \"ip_column\": $IP_COLUMN,"
        echo "      \"ip_detected\": $IP_DETECTED,"
        echo "      \"username_column\": $USERNAME_COLUMN,"
        echo "      \"password_column\": $PASSWORD_COLUMN,"
        echo "      \"ssh_key_column\": $SSH_KEY_COLUMN,"
        echo "      \"credentials_detected\": $CREDS_DETECTED"
        echo "    },"
        echo "    \"description\": \"Clean user credentials with Header-Based Dynamic Detection V2\""
        echo "  },"
        echo "  \"users\": ["
    } >"$OUTPUT_JSON"

    # Add users data
    local user_count=0
    local total_users=$(wc -l <"$final_users" 2>/dev/null || echo "0")

    if [[ $total_users -gt 0 ]]; then
        while IFS='|' read -r username password ssh_key ips; do
            ((user_count++))

            # Escape JSON strings properly
            local escaped_password=$(escape_json "$password")
            local escaped_ssh_key=$(escape_json "$ssh_key")

            # Convert comma-separated IPs to JSON array
            local ip_array=""
            IFS=',' read -ra IP_LIST <<<"$ips"
            for i in "${!IP_LIST[@]}"; do
                if [[ $i -eq 0 ]]; then
                    ip_array="\"${IP_LIST[i]}\""
                else
                    ip_array="$ip_array, \"${IP_LIST[i]}\""
                fi
            done

            # Add user entry (array format)
            {
                if [[ $user_count -gt 1 ]]; then
                    echo "    ,"
                fi
                echo "    {"
                echo "      \"username\": \"$username\","
                echo "      \"password\": \"$escaped_password\","
                echo "      \"ssh_public_key\": \"$escaped_ssh_key\","
                echo "      \"assigned_ips\": [$ip_array],"
                echo "      \"metadata\": {"
                echo "        \"created_at\": \"$current_date\","
                echo "        \"last_updated\": \"$current_date\","
                echo "        \"ip_count\": ${#IP_LIST[@]}"
                echo "      }"
                echo "    }"
            } >>"$OUTPUT_JSON"

        done <"$final_users"
    fi

    # Close users array and start ip_mappings
    {
        echo "  ],"
        echo "  \"ip_mappings\": {"
    } >>"$OUTPUT_JSON"

    # Add IP mappings
    local ip_count=0
    local total_ips=$(wc -l <"$final_ips" 2>/dev/null || echo "0")

    if [[ $total_ips -gt 0 ]]; then
        while IFS='|' read -r ip users; do
            ((ip_count++))

            # Convert comma-separated users to JSON array
            local user_array=""
            IFS=',' read -ra USER_LIST <<<"$users"
            for i in "${!USER_LIST[@]}"; do
                if [[ $i -eq 0 ]]; then
                    user_array="\"${USER_LIST[i]}\""
                else
                    user_array="$user_array, \"${USER_LIST[i]}\""
                fi
            done

            # Add IP mapping entry
            if [[ $ip_count -lt $total_ips ]]; then
                echo "    \"$ip\": [$user_array]," >>"$OUTPUT_JSON"
            else
                echo "    \"$ip\": [$user_array]" >>"$OUTPUT_JSON"
            fi

        done <"$final_ips"
    fi

    # Close JSON structure
    {
        echo "  }"
        echo "}"
    } >>"$OUTPUT_JSON"
}

# Validate generated JSON
validate_json() {
    log "🔍 Validating generated JSON..." "$CYAN"

    if ! jq empty "$OUTPUT_JSON" 2>/dev/null; then
        error_exit "Generated JSON is invalid"
    fi

    # Get statistics from JSON
    local user_count=$(jq '.users | length' "$OUTPUT_JSON")
    local ip_count=$(jq '.ip_mappings | length' "$OUTPUT_JSON")
    local total_assignments=$(jq '[.users[].assigned_ips | length] | add // 0' "$OUTPUT_JSON")

    log "✅ JSON validation passed" "$GREEN"
    log "📊 Final statistics:" "$BLUE"
    log "   - Users: $user_count" "$CYAN"
    log "   - IPs: $ip_count" "$CYAN"
    log "   - Total IP assignments: $total_assignments" "$CYAN"

    # Calculate file sizes
    if [[ -f "$USER_LIST_FILE" ]] && [[ -f "$USER_CREDS_FILE" ]]; then
        local input1_size=$(du -h "$USER_LIST_FILE" | cut -f1)
        local input2_size=$(du -h "$USER_CREDS_FILE" | cut -f1)
        local output_size=$(du -h "$OUTPUT_JSON" | cut -f1)

        log "💾 File sizes:" "$BLUE"
        log "   - Input user list: $input1_size" "$CYAN"
        log "   - Input credentials: $input2_size" "$CYAN"
        log "   - Output JSON: $output_size" "$CYAN"
    fi

    # Perform data integrity checks
    log "🔍 Performing data integrity checks..." "$CYAN"

    # Check for users with no IPs
    local users_no_ips=$(jq '[.users[] | select(.assigned_ips | length == 0)] | length' "$OUTPUT_JSON")
    if [[ $users_no_ips -gt 0 ]]; then
        log "⚠️  Warning: $users_no_ips users have no assigned IPs" "$YELLOW"
    fi

    # Check for IPs with no users
    local ips_no_users=$(jq '[.ip_mappings[] | select(length == 0)] | length' "$OUTPUT_JSON")
    if [[ $ips_no_users -gt 0 ]]; then
        log "⚠️  Warning: $ips_no_users IPs have no assigned users" "$YELLOW"
    fi

    # Sample a few users to check password integrity
    log "🔍 Checking password integrity..." "$CYAN"
    local users_with_empty_passwords=$(jq '[.users[] | select(.password == "")] | length' "$OUTPUT_JSON")
    if [[ $users_with_empty_passwords -gt 0 ]]; then
        log "❌ Error: $users_with_empty_passwords users have empty passwords" "$RED"
    else
        log "✅ All users have non-empty passwords" "$GREEN"
    fi
}

# Show sample output
show_sample() {
    log "🔍 Sample JSON output:" "$BLUE"
    echo
    jq -C '.' "$OUTPUT_JSON" | head -30
    echo
    log "📄 Full output saved to: $OUTPUT_JSON" "$GREEN"
}

# Main execution
main() {
    log "🚀 Starting direct clean user credentials extraction..." "$GREEN"
    echo

    # Setup cleanup trap
    trap cleanup_temp EXIT

    # Execute pipeline
    check_dependencies
    validate_input

    # NEW: Dynamic column detection
    detect_user_list_columns
    detect_user_creds_columns

    parse_raw_data
    generate_json
    validate_json
    show_sample

    echo
    log "✅ Header-Based Dynamic CSV extraction completed successfully!" "$GREEN"
    log "📁 Output file: $OUTPUT_JSON" "$CYAN"

    # Show detection results
    log "🎯 Column Detection Results:" "$BLUE"
    log "   - IP Private: Column $IP_COLUMN ($([ "$IP_DETECTED" == "true" ] && echo "detected" || echo "default"))" "$CYAN"
    log "   - Username: Column $USERNAME_COLUMN ($([ "$CREDS_DETECTED" == "true" ] && echo "detected" || echo "default"))" "$CYAN"
    log "   - Password: Column $PASSWORD_COLUMN ($([ "$CREDS_DETECTED" == "true" ] && echo "detected" || echo "default"))" "$CYAN"
    log "   - SSH Key: Column $SSH_KEY_COLUMN ($([ "$CREDS_DETECTED" == "true" ] && echo "detected" || echo "default"))" "$CYAN"

    log "🎯 Ready for use with pam-agent-v3.sh" "$BLUE"
    log "🔄 This extraction is now resistant to CSV structure changes!" "$GREEN"
}

# Run main function
main "$@"
