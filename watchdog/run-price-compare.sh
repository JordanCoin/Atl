#!/bin/bash
# Mobile Safari Watchdog - Multi-Store Price Comparison
# Runs the same product check across multiple retailers with V2 extraction

set -e

WORKFLOW_FILE="$1"
WATCHDOG_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNS_DIR="$WATCHDOG_DIR/runs"
COOKIE_DIR="$HOME/Library/Application Support/Atl/Cookies"
SERVER="http://localhost:9222"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log() { echo -e "${BLUE}[Compare]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }
store_header() { echo -e "\n${MAGENTA}${BOLD}━━━ $1 ━━━${NC}"; }
confidence_badge() {
    local conf=$1
    local level=$2
    case $level in
        "high") echo -e "${GREEN}●${NC} $conf" ;;
        "medium") echo -e "${YELLOW}●${NC} $conf" ;;
        "low") echo -e "${RED}●${NC} $conf" ;;
        *) echo -e "${DIM}●${NC} $conf" ;;
    esac
}

if [ -z "$WORKFLOW_FILE" ]; then
    echo "Usage: $0 <price-compare-workflow.json>"
    exit 1
fi

if [ ! -f "$WORKFLOW_FILE" ]; then
    error "Workflow file not found: $WORKFLOW_FILE"
    exit 1
fi

# Parse workflow
WORKFLOW_ID=$(jq -r '.id' "$WORKFLOW_FILE")
WORKFLOW_NAME=$(jq -r '.name' "$WORKFLOW_FILE")
PROFILE=$(jq -r '.profile // "default"' "$WORKFLOW_FILE")
STORE_COUNT=$(jq '.stores | length' "$WORKFLOW_FILE")
EXTRACTION_VERSION=$(jq -r '.extractionVersion // "v1"' "$WORKFLOW_FILE")
MIN_CONFIDENCE=$(jq -r '.comparison.minConfidence // 0.6' "$WORKFLOW_FILE")

# Setup run directory
RUN_ID="${WORKFLOW_ID}-$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$RUNS_DIR/$RUN_ID"
mkdir -p "$RUN_DIR/stores" "$RUN_DIR/screenshots" "$RUN_DIR/artifacts"

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "${BOLD}Mobile Safari Watchdog - Price Comparison${NC}"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Workflow: $WORKFLOW_NAME"
log "Run ID:   $RUN_ID"
log "Stores:   $STORE_COUNT retailers"
log "Extraction: $(echo "$EXTRACTION_VERSION" | tr '[:lower:]' '[:upper:]')"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check server
if ! curl -s "$SERVER/ping" | grep -q "ok"; then
    error "Server not responding at $SERVER"
    exit 1
fi
success "Server connected"

# Initialize results array
declare -a STORE_RESULTS
LOWEST_PRICE=999999
LOWEST_STORE=""
HIGHEST_PRICE=0
HIGHEST_STORE=""
SUCCESS_COUNT=0
FAILED_STORES=""
LOW_CONFIDENCE_STORES=""

# Process each store
for i in $(seq 0 $((STORE_COUNT - 1))); do
    STORE=$(jq ".stores[$i]" "$WORKFLOW_FILE")
    STORE_ID=$(echo "$STORE" | jq -r '.id')
    STORE_NAME=$(echo "$STORE" | jq -r '.name')
    STORE_URL=$(echo "$STORE" | jq -r '.url')
    PAGE_VALIDATION=$(echo "$STORE" | jq -c '.pageValidation // {}')
    VALUE_VALIDATION=$(echo "$STORE" | jq -c '.validation.price // {}')

    store_header "$STORE_NAME"

    # Navigate to store
    log "Loading $STORE_URL"
    GOTO_RESP=$(curl -s -X POST "$SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"goto-$STORE_ID\",\"method\":\"goto\",\"params\":{\"url\":\"$STORE_URL\"}}")

    if [ "$(echo "$GOTO_RESP" | jq -r '.success')" != "true" ]; then
        error "Failed to load $STORE_NAME"
        FAILED_STORES="$FAILED_STORES $STORE_ID"
        continue
    fi

    # Wait for page to stabilize
    sleep 3

    # Extract title (simple extract for now)
    TITLE_SELECTORS=$(echo "$STORE" | jq -c '.selectors.title')
    TITLE_RESP=$(curl -s -X POST "$SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"title-$STORE_ID\",\"method\":\"extract\",\"params\":{\"selector\":$TITLE_SELECTORS}}")
    TITLE=$(echo "$TITLE_RESP" | jq -r '.result.value // "Unknown"' | head -c 80)

    # Extract price using V2 extraction
    PRICE_SELECTORS=$(echo "$STORE" | jq -c '.selectors.price')

    if [ "$EXTRACTION_VERSION" = "v2" ]; then
        # Use extractV2 with page validation and confidence scoring
        PRICE_RESP=$(curl -s -X POST "$SERVER/command" \
            -H "Content-Type: application/json" \
            -d "{
                \"id\":\"price-$STORE_ID\",
                \"method\":\"extractV2\",
                \"params\":{
                    \"selector\":$PRICE_SELECTORS,
                    \"pageValidation\":$PAGE_VALIDATION,
                    \"validation\":$VALUE_VALIDATION
                }
            }")

        PRICE=$(echo "$PRICE_RESP" | jq -r '.result.value // "null"')
        PRICE_CONFIDENCE=$(echo "$PRICE_RESP" | jq -r '.result.confidence // 0')
        PRICE_CONF_LEVEL=$(echo "$PRICE_RESP" | jq -r '.result.confidenceLevel // "unknown"')
        PRICE_METHOD=$(echo "$PRICE_RESP" | jq -r '.result.method // "unknown"')
        PRICE_SELECTOR=$(echo "$PRICE_RESP" | jq -r '.result.selectorUsed // "none"')
        PAGE_PASSED=$(echo "$PRICE_RESP" | jq -r '.result.pageValidation.passed // true')
        VALIDATION_ERRORS=$(echo "$PRICE_RESP" | jq -r '.result.validationErrors | join(", ") // ""')
        IS_RELIABLE=$(echo "$PRICE_RESP" | jq -r '.result.isReliable // false')
        CANDIDATES=$(echo "$PRICE_RESP" | jq -r '.result.candidates // []')
        FAILED_CHECKS=$(echo "$PRICE_RESP" | jq -r '.result.pageValidation.failedChecks | join(", ") // ""')

        # Check page validation
        if [ "$PAGE_PASSED" != "true" ]; then
            error "Page validation failed: $FAILED_CHECKS"
            FAILED_STORES="$FAILED_STORES $STORE_ID"

            # Save artifacts for debugging
            echo "$PRICE_RESP" | jq . > "$RUN_DIR/artifacts/${STORE_ID}-extraction.json"
            continue
        fi
    else
        # Legacy V1 extraction
        PRICE_RESP=$(curl -s -X POST "$SERVER/command" \
            -H "Content-Type: application/json" \
            -d "{\"id\":\"price-$STORE_ID\",\"method\":\"extract\",\"params\":{\"selector\":$PRICE_SELECTORS}}")
        PRICE=$(echo "$PRICE_RESP" | jq -r '.result.value // "null"')
        PRICE_SELECTOR=$(echo "$PRICE_RESP" | jq -r '.result.selectorUsed // "none"')
        PRICE_CONFIDENCE="1.0"
        PRICE_CONF_LEVEL="high"
        PRICE_METHOD="legacy"
        IS_RELIABLE="true"
    fi

    # Extract availability
    AVAIL_SELECTORS=$(echo "$STORE" | jq -c '.selectors.availability')
    AVAIL_RESP=$(curl -s -X POST "$SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"avail-$STORE_ID\",\"method\":\"extract\",\"params\":{\"selector\":$AVAIL_SELECTORS}}")
    AVAILABILITY=$(echo "$AVAIL_RESP" | jq -r '.result.value // "Unknown"')

    # Take screenshot
    SCREENSHOT_RESP=$(curl -s -X POST "$SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"screenshot-$STORE_ID\",\"method\":\"screenshot\",\"params\":{\"fullPage\":true}}")
    echo "$SCREENSHOT_RESP" | jq -r '.result.data // empty' | base64 -d > "$RUN_DIR/screenshots/${STORE_ID}.pdf" 2>/dev/null

    # Validate and display results
    if [ "$PRICE" != "null" ] && [ -n "$PRICE" ]; then
        PRICE_NUM=$(echo "$PRICE" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
        if [ -n "$PRICE_NUM" ]; then
            # Display with confidence badge
            CONF_BADGE=$(confidence_badge "$PRICE_CONFIDENCE" "$PRICE_CONF_LEVEL")
            success "Price: \$${PRICE_NUM} [$CONF_BADGE] via $PRICE_METHOD"

            # Check confidence threshold
            if (( $(echo "$PRICE_CONFIDENCE < $MIN_CONFIDENCE" | bc -l) )); then
                warn "Low confidence ($PRICE_CONFIDENCE < $MIN_CONFIDENCE)"
                LOW_CONFIDENCE_STORES="$LOW_CONFIDENCE_STORES $STORE_ID"
            fi

            # Track lowest/highest (only if reliable)
            if [ "$IS_RELIABLE" = "true" ] || (( $(echo "$PRICE_CONFIDENCE >= $MIN_CONFIDENCE" | bc -l) )); then
                if (( $(echo "$PRICE_NUM < $LOWEST_PRICE" | bc -l) )); then
                    LOWEST_PRICE=$PRICE_NUM
                    LOWEST_STORE=$STORE_NAME
                fi
                if (( $(echo "$PRICE_NUM > $HIGHEST_PRICE" | bc -l) )); then
                    HIGHEST_PRICE=$PRICE_NUM
                    HIGHEST_STORE=$STORE_NAME
                fi
            fi

            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            warn "Price extraction failed"
            PRICE_NUM="null"
        fi
    else
        warn "Price not found"
        PRICE_NUM="null"
        if [ -n "$VALIDATION_ERRORS" ]; then
            echo -e "  ${DIM}Errors: $VALIDATION_ERRORS${NC}"
        fi
    fi

    echo "  Title: $TITLE"
    echo "  Availability: $AVAILABILITY"
    if [ "$EXTRACTION_VERSION" = "v2" ]; then
        echo -e "  ${DIM}Method: $PRICE_METHOD | Selector: $PRICE_SELECTOR${NC}"
    fi

    # Save store result with V2 metadata
    cat > "$RUN_DIR/stores/${STORE_ID}.json" << STORE_EOF
{
  "storeId": "$STORE_ID",
  "storeName": "$STORE_NAME",
  "url": "$STORE_URL",
  "title": "$TITLE",
  "price": $PRICE_NUM,
  "confidence": $PRICE_CONFIDENCE,
  "confidenceLevel": "$PRICE_CONF_LEVEL",
  "method": "$PRICE_METHOD",
  "selectorUsed": "$PRICE_SELECTOR",
  "isReliable": $IS_RELIABLE,
  "availability": "$AVAILABILITY",
  "screenshot": "$RUN_DIR/screenshots/${STORE_ID}.pdf",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
STORE_EOF

    sleep 1
done

# Calculate savings
if [ "$LOWEST_PRICE" != "999999" ] && [ "$HIGHEST_PRICE" != "0" ]; then
    SAVINGS=$(echo "$HIGHEST_PRICE - $LOWEST_PRICE" | bc -l)
    SAVINGS_PCT=$(echo "scale=1; ($SAVINGS / $HIGHEST_PRICE) * 100" | bc -l)
else
    SAVINGS=0
    SAVINGS_PCT=0
fi

# Generate comparison report
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "${BOLD}PRICE COMPARISON RESULTS${NC}"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
if [ "$LOWEST_PRICE" != "999999" ]; then
    echo -e "${GREEN}${BOLD}🏆 LOWEST PRICE: \$${LOWEST_PRICE} at ${LOWEST_STORE}${NC}"
    echo -e "${RED}   HIGHEST:      \$${HIGHEST_PRICE} at ${HIGHEST_STORE}${NC}"
    echo -e "${CYAN}   SAVINGS:      \$${SAVINGS} (${SAVINGS_PCT}% off highest)${NC}"
else
    warn "No valid prices found"
fi

echo ""
echo "Stores checked: $SUCCESS_COUNT / $STORE_COUNT"
if [ -n "$FAILED_STORES" ]; then
    error "Failed stores:$FAILED_STORES"
fi
if [ -n "$LOW_CONFIDENCE_STORES" ]; then
    warn "Low confidence:$LOW_CONFIDENCE_STORES"
fi

# Create final report
REPORT_FILE="$RUN_DIR/comparison-report.json"

cat > "$REPORT_FILE" << EOF
{
  "runId": "$RUN_ID",
  "workflowId": "$WORKFLOW_ID",
  "workflowName": "$WORKFLOW_NAME",
  "extractionVersion": "$EXTRACTION_VERSION",
  "minConfidence": $MIN_CONFIDENCE,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "storesChecked": $STORE_COUNT,
  "storesSucceeded": $SUCCESS_COUNT,
  "failedStores": "$(echo $FAILED_STORES | xargs)",
  "lowConfidenceStores": "$(echo $LOW_CONFIDENCE_STORES | xargs)",
  "comparison": {
    "lowestPrice": $LOWEST_PRICE,
    "lowestStore": "$LOWEST_STORE",
    "highestPrice": $HIGHEST_PRICE,
    "highestStore": "$HIGHEST_STORE",
    "savings": $SAVINGS,
    "savingsPercent": $SAVINGS_PCT
  },
  "storeResults": $(ls -1 "$RUN_DIR/stores/"*.json 2>/dev/null | xargs -I{} cat {} | jq -s '.')
}
EOF

log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
success "Comparison complete: $RUN_ID"
log "Report: $REPORT_FILE"
log "Screenshots: $RUN_DIR/screenshots/"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
