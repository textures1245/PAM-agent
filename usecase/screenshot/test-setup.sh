
#!/opt/homebrew/bin/bash

# Quick validation test for CIS PAM Capture Agent
# Tests basic functionality without connecting to VMs

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${2:-$NC}${1}${NC}"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASSED=0
FAILED=0

log "🧪 CIS PAM Capture Agent - Validation Tests" "$BLUE"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "$BLUE"
echo ""

# Test 1: Check script files exist
log "Test 1: Script files existence" "$BLUE"
for script in data-adapter.sh termshot.sh cis-pam-capture-agent.sh; do
    if [[ -f "$SCRIPT_DIR/$script" ]]; then
        log "  ✓ $script exists" "$GREEN"
        ((PASSED++))
    else
        log "  ✗ $script missing" "$RED"
        ((FAILED++))
    fi
done
echo ""

# Test 2: Check executability
log "Test 2: Script executability" "$BLUE"
for script in data-adapter.sh termshot.sh cis-pam-capture-agent.sh; do
    if [[ -x "$SCRIPT_DIR/$script" ]]; then
        log "  ✓ $script is executable" "$GREEN"
        ((PASSED++))
    else
        log "  ✗ $script not executable" "$RED"
        ((FAILED++))
    fi
done
echo ""

# Test 3: Check JSON file
log "Test 3: JSON file availability" "$BLUE"
JSON_FILE="$SCRIPT_DIR/../../user_credentials_clean.json"
if [[ -f "$JSON_FILE" ]]; then
    log "  ✓ user_credentials_clean.json found" "$GREEN"
    ((PASSED++))
    
    # Validate JSON syntax
    if command -v jq &>/dev/null; then
        if jq empty "$JSON_FILE" 2>/dev/null; then
            log "  ✓ JSON syntax valid" "$GREEN"
            ((PASSED++))
        else
            log "  ✗ JSON syntax invalid" "$RED"
            ((FAILED++))
        fi
    else
        log "  ⚠ jq not installed, skipping JSON validation" "$YELLOW"
    fi
else
    log "  ✗ user_credentials_clean.json not found" "$RED"
    ((FAILED++))
fi
echo ""

# Test 4: Check required commands
log "Test 4: Required system commands" "$BLUE"
for cmd in bash ssh scp python3 pip3; do
    if command -v "$cmd" &>/dev/null; then
        log "  ✓ $cmd available" "$GREEN"
        ((PASSED++))
    else
        log "  ✗ $cmd not found" "$RED"
        ((FAILED++))
    fi
done
echo ""

# Test 5: Test data-adapter functionality
log "Test 5: Data adapter test run" "$BLUE"
if [[ -f "$JSON_FILE" ]]; then
    if bash "$SCRIPT_DIR/data-adapter.sh" "$JSON_FILE" &>/dev/null; then
        log "  ✓ Data adapter executed successfully" "$GREEN"
        ((PASSED++))
        
        if [[ -f "$SCRIPT_DIR/termshot-data.sh" ]]; then
            log "  ✓ termshot-data.sh generated" "$GREEN"
            ((PASSED++))
            
            # Clean up
            rm -f "$SCRIPT_DIR/termshot-data.sh"
        else
            log "  ✗ termshot-data.sh not generated" "$RED"
            ((FAILED++))
        fi
    else
        log "  ✗ Data adapter failed" "$RED"
        ((FAILED++))
    fi
else
    log "  ⚠ Skipping (JSON file missing)" "$YELLOW"
fi
echo ""

# Test 6: Test termshot.sh sourcing
log "Test 6: Termshot utility functions" "$BLUE"
if source "$SCRIPT_DIR/termshot.sh" 2>/dev/null; then
    log "  ✓ termshot.sh sourced successfully" "$GREEN"
    ((PASSED++))
    
    # Check if functions are defined
    if declare -f ts_log &>/dev/null; then
        log "  ✓ Functions loaded correctly" "$GREEN"
        ((PASSED++))
    else
        log "  ✗ Functions not loaded" "$RED"
        ((FAILED++))
    fi
else
    log "  ✗ Failed to source termshot.sh" "$RED"
    ((FAILED++))
fi
echo ""

# Test 7: Python dependencies
log "Test 7: Python dependencies check" "$BLUE"
if python3 -c "import openpyxl" 2>/dev/null; then
    log "  ✓ openpyxl installed" "$GREEN"
    ((PASSED++))
else
    log "  ⚠ openpyxl not installed (will auto-install)" "$YELLOW"
fi

if python3 -c "import PIL" 2>/dev/null; then
    log "  ✓ pillow installed" "$GREEN"
    ((PASSED++))
else
    log "  ⚠ pillow not installed (will auto-install)" "$YELLOW"
fi
echo ""

# Summary
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "$BLUE"
log "📊 Test Summary" "$BLUE"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "$BLUE"
log "  ✅ Passed: $PASSED" "$GREEN"
log "  ❌ Failed: $FAILED" "$RED"
TOTAL=$((PASSED + FAILED))
log "  📊 Total: $TOTAL" "$BLUE"
echo ""

if [[ $FAILED -eq 0 ]]; then
    log "✅ All tests passed! Ready to run CIS PAM Capture Agent." "$GREEN"
    echo ""
    log "To execute:" "$BLUE"
    log "  cd $SCRIPT_DIR" "$CYAN"
    log "  ./cis-pam-capture-agent.sh" "$CYAN"
    exit 0
else
    log "⚠️  Some tests failed. Please fix issues before running." "$YELLOW"
    exit 1
fi
