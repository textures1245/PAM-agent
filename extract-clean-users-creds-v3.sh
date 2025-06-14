#!/bin/bash

# Extract Clean User Credentials Script V3 - User-Centric with IP Boolean Columns
# Enhanced for unified CSV template architecture with interactive path input
# Extracts user credentials from single unified CSV file and generates clean JSON format
# Eliminates data duplication by using username as primary key
#
# Input: User-specified unified CSV file (User-Centric with IP Boolean Columns)
# Output: user_credentials_clean.json (written to current directory)
#
# Features:
# - NEW: Interactive CSV file path input
# - Single unified CSV file processing (raw_user_list_v2.csv format)
# - User-Centric with IP Boolean Columns support
# - Dynamic column detection for Username, Password, SSH_Public_Key
# - PRIVATE_ prefix IP column detection and extraction
# - Boolean-to-array IP assignment conversion (TRUE/FALSE → IP arrays)
# - "User " prefix row detection and username extraction
# - Robust error handling without strict mode
# - Enhanced metadata tracking for column/row detection
#
# Version: 3.0 - Unified CSV Template with Interactive Path Input
# Created: 2025-06-13

# Graceful error handling - no strict mode for production stability
set -eo pipefail

# Global variables
RAW_CSV=""
OUTPUT_JSON="./user_credentials_clean.json"
TEMP_DIR="/tmp/clean_users_v3_$$"

# Column position variables (will be detected dynamically)
USERNAME_COLUMN=0
PASSWORD_COLUMN=1
SSH_KEY_COLUMN=2
IP_COLUMNS=()

# Detection flags and counters
USERNAME_DETECTED=false
PASSWORD_DETECTED=false
SSH_KEY_DETECTED=false
IP_COLUMNS_DETECTED=false
TOTAL_ROWS=0
VALID_ROWS=0

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

# Error handling with graceful continuation
error_exit() {
    log "❌ ERROR: $1" "$RED"
    cleanup_temp
    exit 1
}

# Warning handler - continue processing
warning_log() {
    log "⚠️  WARNING: $1" "$YELLOW"
}

# Get CSV file path from user
get_csv_file_path() {
    log "📁 CSV File Selection" "$BLUE"
    echo

    while true; do
        echo -n "Please enter the path to your unified CSV file: "
        read -r csv_path

        # Expand tilde and relative paths
        csv_path="${csv_path/#\~/$HOME}"
        csv_path="$(realpath "$csv_path" 2>/dev/null || echo "$csv_path")"

        if [[ -z "$csv_path" ]]; then
            warning_log "Path cannot be empty. Please try again."
            continue
        fi

        if [[ ! -f "$csv_path" ]]; then
            warning_log "File not found: $csv_path"
            echo -n "Would you like to try again? (y/n): "
            read -r retry
            if [[ ! "$retry" =~ ^[Yy] ]]; then
                error_exit "User cancelled file selection"
            fi
            continue
        fi

        if [[ ! -r "$csv_path" ]]; then
            warning_log "File is not readable: $csv_path"
            continue
        fi

        # Validate it's a CSV file
        if [[ ! "$csv_path" =~ \.(csv|CSV)$ ]]; then
            log "⚠️  File doesn't have .csv extension. Continue anyway? (y/n): " "$YELLOW"
            read -r continue_anyway
            if [[ ! "$continue_anyway" =~ ^[Yy] ]]; then
                continue
            fi
        fi

        RAW_CSV="$csv_path"
        log "✅ Selected CSV file: $RAW_CSV" "$GREEN"
        break
    done
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

# Validate input file
validate_input() {
    log "📄 Validating input file..." "$BLUE"

    if [[ ! -f "$RAW_CSV" ]]; then
        error_exit "CSV file not found: $RAW_CSV"
    fi

    if [[ ! -r "$RAW_CSV" ]]; then
        error_exit "Cannot read CSV file: $RAW_CSV"
    fi

    local csv_lines=$(wc -l <"$RAW_CSV" 2>/dev/null || echo "0")

    if [[ $csv_lines -lt 4 ]]; then
        error_exit "CSV file contains insufficient data (need at least 3 header rows + 1 data row)"
    fi

    log "✅ Input validation passed" "$GREEN"
    log "   - CSV file: $RAW_CSV" "$CYAN"
    log "   - Total lines: $csv_lines" "$CYAN"
    log "   - Expected data rows: $((csv_lines - 3))" "$CYAN"
}

# Dynamic column detection for unified CSV template
detect_columns() {
    log "🔍 Detecting unified CSV column structure..." "$BLUE"

    # Read the first header row for basic columns
    local header_line=$(sed -n '1p' "$RAW_CSV")

    # Parse header fields
    local temp_fields="/tmp/header_fields_$$"
    parse_csv_line "$header_line" >"$temp_fields"

    local column_index=0
    IP_COLUMNS=()

    # Check each column header for basic columns (Username, Password, SSH_Public_Key)
    while IFS= read -r field; do
        clean_field_value=$(clean_field "$field")

        # Check for Username column
        if [[ "$clean_field_value" =~ ^[Uu]sername$ ]] && [[ "$USERNAME_DETECTED" == "false" ]]; then
            USERNAME_COLUMN=$column_index
            USERNAME_DETECTED=true
            log "✅ Found Username column at position $column_index" "$GREEN"
        fi

        # Check for Password column
        if [[ "$clean_field_value" =~ ^[Pp]assword$ ]] && [[ "$PASSWORD_DETECTED" == "false" ]]; then
            PASSWORD_COLUMN=$column_index
            PASSWORD_DETECTED=true
            log "✅ Found Password column at position $column_index" "$GREEN"
        fi

        # Check for SSH_Public_Key column
        if [[ "$clean_field_value" =~ ^SSH_Public_Key$ ]] && [[ "$SSH_KEY_DETECTED" == "false" ]]; then
            SSH_KEY_COLUMN=$column_index
            SSH_KEY_DETECTED=true
            log "✅ Found SSH_Public_Key column at position $column_index" "$GREEN"
        fi

        ((column_index++))
    done <"$temp_fields"

    rm -f "$temp_fields"

    # Now check the 3rd header row for PRIVATE_ IP columns
    local ip_header_line=$(sed -n '3p' "$RAW_CSV")
    local temp_ip_fields="/tmp/ip_header_fields_$$"
    parse_csv_line "$ip_header_line" >"$temp_ip_fields"

    column_index=0
    # Check each column header for IP columns
    while IFS= read -r field; do
        clean_field_value=$(clean_field "$field")

        # Check for PRIVATE_ IP columns
        if [[ "$clean_field_value" =~ ^PRIVATE_([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
            IP_COLUMNS+=("$column_index:${BASH_REMATCH[1]}")
            log "✅ Found IP column at position $column_index: ${BASH_REMATCH[1]}" "$GREEN"
        fi

        ((column_index++))
    done <"$temp_ip_fields"

    rm -f "$temp_ip_fields"

    # Check detection results
    if [[ "$USERNAME_DETECTED" == "true" ]] && [[ "$PASSWORD_DETECTED" == "true" ]] && [[ "$SSH_KEY_DETECTED" == "true" ]]; then
        log "✅ All credential columns detected successfully" "$GREEN"
    else
        log "❌ Missing required columns:" "$RED"
        [[ "$USERNAME_DETECTED" == "false" ]] && log "   - Username column not found" "$RED"
        [[ "$PASSWORD_DETECTED" == "false" ]] && log "   - Password column not found" "$RED"
        [[ "$SSH_KEY_DETECTED" == "false" ]] && log "   - SSH_Public_Key column not found" "$RED"
        error_exit "Required columns not found in CSV header"
    fi

    if [[ ${#IP_COLUMNS[@]} -gt 0 ]]; then
        IP_COLUMNS_DETECTED=true
        log "✅ Found ${#IP_COLUMNS[@]} IP columns with PRIVATE_ prefix" "$GREEN"
    else
        warning_log "No IP columns with PRIVATE_ prefix found"
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

# Parse unified CSV and extract user data with boolean IP logic
parse_unified_csv() {
    log "📊 Parsing unified CSV data with boolean IP logic..." "$CYAN"

    mkdir -p "$TEMP_DIR"

    # Create temporary files for processing
    local users_data="$TEMP_DIR/users_data.tmp"
    local ip_data="$TEMP_DIR/ip_data.tmp"

    # Clear temp files
    >"$users_data"
    >"$ip_data"

    log "🔍 Processing user rows and IP assignments..." "$BLUE"

    # Initialize counters
    TOTAL_ROWS=0
    VALID_ROWS=0

    # Process each data row starting from line 4 (skip 3 header rows)
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*$ ]]; then
            continue
        fi

        TOTAL_ROWS=$((TOTAL_ROWS + 1))

        # Parse CSV line properly handling quotes
        temp_fields="/tmp/fields_$$"
        parse_csv_line "$line" >"$temp_fields"

        # Read fields into array
        FIELDS=()
        while IFS= read -r field; do
            FIELDS+=("$field")
        done <"$temp_fields"
        rm -f "$temp_fields"

        # Check minimum required columns
        if [[ ${#FIELDS[@]} -lt $((SSH_KEY_COLUMN + 1)) ]]; then
            warning_log "Line $TOTAL_ROWS: Insufficient columns (${#FIELDS[@]}), skipping"
            continue
        fi

        # Extract username from "User username" pattern
        local username_field=$(clean_field "${FIELDS[$USERNAME_COLUMN]}")
        local username=""

        if [[ "$username_field" =~ ^User[[:space:]]+([a-zA-Z0-9_-]+)$ ]]; then
            username="${BASH_REMATCH[1]}"
        else
            warning_log "Line $TOTAL_ROWS: Invalid username format '$username_field', skipping"
            continue
        fi

        # Extract password and SSH key
        local password=$(clean_field "${FIELDS[$PASSWORD_COLUMN]}")
        local ssh_key=$(clean_field "${FIELDS[$SSH_KEY_COLUMN]}")

        if [[ -z "$password" ]]; then
            warning_log "Line $TOTAL_ROWS: Empty password for user '$username', skipping"
            continue
        fi

        log "  Processing user: $username" "$CYAN"

        # Process IP columns and boolean logic
        local assigned_ips=""
        for ip_column_info in "${IP_COLUMNS[@]}"; do
            local column_index="${ip_column_info%%:*}"
            local ip_address="${ip_column_info##*:}"

            if [[ $column_index -lt ${#FIELDS[@]} ]]; then
                local boolean_value=$(clean_field "${FIELDS[$column_index]}")

                # Check if user has access to this IP (TRUE values)
                if [[ "$boolean_value" =~ ^(TRUE|true|True|1|yes|Yes|YES)$ ]]; then
                    if [[ -z "$assigned_ips" ]]; then
                        assigned_ips="$ip_address"
                    else
                        assigned_ips="$assigned_ips,$ip_address"
                    fi

                    # Add to IP mapping data
                    echo "$ip_address|$username" >>"$ip_data"
                fi
            fi
        done

        # Store user data
        echo "$username|$password|$ssh_key|$assigned_ips" >>"$users_data"
        VALID_ROWS=$((VALID_ROWS + 1))

    done < <(tail -n +4 "$RAW_CSV")

    log "📈 CSV parsing completed:" "$BLUE"
    log "   - Total rows processed: $TOTAL_ROWS" "$CYAN"
    log "   - Valid user rows: $VALID_ROWS" "$CYAN"
    log "   - Users with IP assignments: $(wc -l <"$users_data" 2>/dev/null || echo "0")" "$CYAN"
    log "   - Total IP assignments: $(wc -l <"$ip_data" 2>/dev/null || echo "0")" "$CYAN"

    # Now aggregate the data to eliminate duplicates
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
        while IFS='|' read -r username password ssh_key ips; do
            if ! grep -q "^$username$" "$user_order" 2>/dev/null; then
                echo "$username" >>"$user_order"
            fi
        done <"$users_data"
    fi

    # Process each user to create final user data
    if [[ -f "$users_data" ]]; then
        while IFS= read -r ordered_username; do
            # Find the user data (should be unique in unified CSV)
            while IFS='|' read -r username password ssh_key ips; do
                if [[ "$username" == "$ordered_username" ]]; then
                    echo "$ordered_username|$password|$ssh_key|$ips" >>"$final_users"
                    break
                fi
            done <"$users_data"
        done <"$user_order"
    fi

    # Aggregate IP data (group users by IP)
    if [[ -f "$ip_data" ]]; then
        # Get unique IPs in order they appear
        local ip_order="$TEMP_DIR/ip_order.tmp"
        >"$ip_order"

        while IFS='|' read -r ip username; do
            if ! grep -q "^$ip$" "$ip_order" 2>/dev/null; then
                echo "$ip" >>"$ip_order"
            fi
        done <"$ip_data"

        # For each IP, collect users in the order they appear
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

    local unique_users=$(wc -l <"$final_users" 2>/dev/null || echo "0")
    local unique_ips=$(wc -l <"$final_ips" 2>/dev/null || echo "0")

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
}

# Generate JSON output from aggregated data
generate_json() {
    log "🔄 Generating clean JSON structure..." "$CYAN"

    local final_users="$TEMP_DIR/final_users.tmp"
    local final_ips="$TEMP_DIR/final_ips.tmp"
    local current_date=$(date +"%Y-%m-%d")

    # adjust column indices to match JSON format (old values are 1-based index)
    USERNAME_COLUMN=$((USERNAME_COLUMN + 1))
    PASSWORD_COLUMN=$((PASSWORD_COLUMN + 1))
    SSH_KEY_COLUMN=$((SSH_KEY_COLUMN + 1))

    # Start JSON structure
    {
        echo "{"
        echo "  \"metadata\": {"
        echo "    \"generated_at\": \"$current_date\","
        echo "    \"extraction_method\": \"Unified CSV Template V3\","
        echo "    \"source_files\": [\"$(basename "$RAW_CSV")\"],"
        echo "    \"format_version\": \"3.0\","
        echo "    \"column_detection\": {"
        echo "      \"username_column\": $USERNAME_COLUMN,"
        echo "      \"password_column\": $PASSWORD_COLUMN,"
        echo "      \"ssh_key_column\": $SSH_KEY_COLUMN,"
        echo "      \"ip_columns\": ${#IP_COLUMNS[@]},"
        echo "      \"username_detected\": $USERNAME_DETECTED,"
        echo "      \"password_detected\": $PASSWORD_DETECTED,"
        echo "      \"ssh_key_detected\": $SSH_KEY_DETECTED,"
        echo "      \"ip_columns_detected\": $IP_COLUMNS_DETECTED"
        echo "    },"
        echo "    \"row_detection\": {"
        echo "      \"pattern\": \"User \","
        echo "      \"total_rows\": $TOTAL_ROWS,"
        echo "      \"valid_rows\": $VALID_ROWS"
        echo "    },"
        echo "    \"description\": \"Clean user credentials from unified CSV template with IP boolean columns\""
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
    log "🔍 Metadata output:" "$BLUE"
    echo
    jq '.metadata' "$OUTPUT_JSON"
    echo
    log "📄 Full output saved to: $OUTPUT_JSON" "$GREEN"
}

# Main execution
main() {
    log "🚀 PAM Agent V3 - Unified CSV Template Processor" "$GREEN"
    log "📋 Extract Clean User Credentials Script V3" "$BLUE"
    echo

    # Setup cleanup trap
    trap cleanup_temp EXIT

    # NEW: Interactive CSV file path input
    get_csv_file_path
    echo

    # Execute pipeline
    check_dependencies
    validate_input

    # NEW: Dynamic column detection for unified CSV template
    detect_columns

    parse_unified_csv
    generate_json
    validate_json
    show_sample

    echo
    log "✅ Unified CSV Template processing completed successfully!" "$GREEN"
    log "📁 Output file: $OUTPUT_JSON" "$CYAN"

    # Show detection results
    log "🎯 Column Detection Results:" "$BLUE"
    log "   - Username: Column $USERNAME_COLUMN ($([ "$USERNAME_DETECTED" == "true" ] && echo "detected" || echo "default"))" "$CYAN"
    log "   - Password: Column $PASSWORD_COLUMN ($([ "$PASSWORD_DETECTED" == "true" ] && echo "detected" || echo "default"))" "$CYAN"
    log "   - SSH Key: Column $SSH_KEY_COLUMN ($([ "$SSH_KEY_DETECTED" == "true" ] && echo "detected" || echo "default"))" "$CYAN"
    log "   - IP Columns: ${#IP_COLUMNS[@]} found ($([ "$IP_COLUMNS_DETECTED" == "true" ] && echo "detected" || echo "none"))" "$CYAN"

    log "🎯 Ready for use with PAM Agent V4!" "$BLUE"
    log "🔄 This extraction is now resistant to CSV structure changes!" "$GREEN"
}

# Run main function
main "$@"
