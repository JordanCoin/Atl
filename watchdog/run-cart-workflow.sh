#!/bin/bash
# Mobile Safari Watchdog - Cart Flow Workflow
# Executes cart automation and captures training data at each step

set -e

WORKFLOW_FILE="$1"
WATCHDOG_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNS_DIR="$WATCHDOG_DIR/runs"
SERVER="http://localhost:9222"
ML_DIR="$WATCHDOG_DIR/ml"

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

log() { echo -e "${BLUE}[Cart]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }
step_header() { echo -e "\n${MAGENTA}${BOLD}━━━ Step: $1 ━━━${NC}"; }

if [ -z "$WORKFLOW_FILE" ]; then
    echo "Usage: $0 <cart-workflow.json>"
    exit 1
fi

if [ ! -f "$WORKFLOW_FILE" ]; then
    error "Workflow file not found: $WORKFLOW_FILE"
    exit 1
fi

# Parse workflow
WORKFLOW_ID=$(jq -r '.id' "$WORKFLOW_FILE")
WORKFLOW_NAME=$(jq -r '.name' "$WORKFLOW_FILE")
STORE_ID=$(jq -r '.store.id' "$WORKFLOW_FILE")
STORE_NAME=$(jq -r '.store.name' "$WORKFLOW_FILE")
PRODUCT_NAME=$(jq -r '.product.name' "$WORKFLOW_FILE")
PRODUCT_QUERY=$(jq -r '.product.searchQuery' "$WORKFLOW_FILE")
PRODUCT_DESC=$(jq -r '.product.description // ""' "$WORKFLOW_FILE")
CLIP_VERIFICATION=$(jq -r '.product.clipVerification // false' "$WORKFLOW_FILE")
STEP_COUNT=$(jq '.steps | length' "$WORKFLOW_FILE")

# Setup run directory
RUN_ID="${WORKFLOW_ID}-$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$RUNS_DIR/$RUN_ID"
mkdir -p "$RUN_DIR/screenshots" "$RUN_DIR/training" "$RUN_DIR/artifacts"

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "${BOLD}Mobile Safari Watchdog - Cart Flow${NC}"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Workflow: $WORKFLOW_NAME"
log "Store:    $STORE_NAME"
log "Product:  $PRODUCT_NAME"
log "Run ID:   $RUN_ID"
log "Steps:    $STEP_COUNT"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check server
if ! curl -s "$SERVER/ping" | grep -q "ok"; then
    error "Server not responding at $SERVER"
    exit 1
fi
success "Server connected"

# Track results
STEPS_COMPLETED=0
STEPS_FAILED=0
declare -a STEP_RESULTS

# Process each step
for i in $(seq 0 $((STEP_COUNT - 1))); do
    STEP=$(jq ".steps[$i]" "$WORKFLOW_FILE")
    STEP_ID=$(echo "$STEP" | jq -r '.id')
    STEP_NAME=$(echo "$STEP" | jq -r '.name')
    STEP_ACTION=$(echo "$STEP" | jq -r '.action')
    PAGE_TYPE=$(echo "$STEP" | jq -r '.pageType // "unknown"')
    CLIP_PROMPT=$(echo "$STEP" | jq -r '.clipPrompt // ""')

    step_header "$STEP_NAME ($PAGE_TYPE)"

    # Execute action
    case $STEP_ACTION in
        "goto")
            URL=$(echo "$STEP" | jq -r '.url // empty')
            if [ -z "$URL" ]; then
                # Build search URL
                SEARCH_URL=$(jq -r '.store.searchUrl' "$WORKFLOW_FILE")
                URL=$(echo "$SEARCH_URL" | sed "s/{query}/$(echo "$PRODUCT_QUERY" | sed 's/ /+/g')/g")
            fi
            log "Navigating to $URL"
            RESP=$(curl -s -X POST "$SERVER/command" \
                -H "Content-Type: application/json" \
                -d "{\"id\":\"$STEP_ID\",\"method\":\"goto\",\"params\":{\"url\":\"$URL\"}}")
            ;;
        "click")
            TARGET=$(echo "$STEP" | jq -r '.target')
            FALLBACK=$(echo "$STEP" | jq -r '.fallbackTarget // empty')
            log "Clicking $TARGET"
            RESP=$(curl -s -X POST "$SERVER/command" \
                -H "Content-Type: application/json" \
                -d "{\"id\":\"$STEP_ID\",\"method\":\"click\",\"params\":{\"selector\":\"$TARGET\"}}")

            # Try fallback if primary failed
            if [ "$(echo "$RESP" | jq -r '.success')" != "true" ] && [ -n "$FALLBACK" ]; then
                log "Trying fallback: $FALLBACK"
                RESP=$(curl -s -X POST "$SERVER/command" \
                    -H "Content-Type: application/json" \
                    -d "{\"id\":\"${STEP_ID}-fallback\",\"method\":\"click\",\"params\":{\"selector\":\"$FALLBACK\"}}")
            fi
            ;;
    esac

    sleep 3

    # Get page info
    TITLE_RESP=$(curl -s -X POST "$SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"title-$STEP_ID\",\"method\":\"getTitle\",\"params\":{}}")
    # Escape title for JSON (handle quotes, special chars)
    TITLE_RAW=$(echo "$TITLE_RESP" | jq -r '.result.title // "Unknown"' | head -c 80)
    TITLE=$(echo "$TITLE_RAW" | sed 's/"/\\"/g' | sed "s/'/\\'/g" | tr -d '\n\r')

    URL_RESP=$(curl -s -X POST "$SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"url-$STEP_ID\",\"method\":\"getURL\",\"params\":{}}")
    CURRENT_URL=$(echo "$URL_RESP" | jq -r '.result.url // ""')

    # Page validation
    PAGE_VALIDATION=$(echo "$STEP" | jq -c '.pageValidation // {}')
    VALIDATION_PASSED="true"
    if [ "$PAGE_VALIDATION" != "{}" ]; then
        # Check URL contains
        URL_CONTAINS=$(echo "$PAGE_VALIDATION" | jq -r '.urlContains // [] | .[]')
        for pattern in $URL_CONTAINS; do
            if ! echo "$CURRENT_URL" | grep -qi "$pattern"; then
                VALIDATION_PASSED="false"
                warn "URL missing: $pattern"
            fi
        done

        # Check title contains
        TITLE_CONTAINS=$(echo "$PAGE_VALIDATION" | jq -r '.titleContains // [] | .[]')
        for pattern in $TITLE_CONTAINS; do
            if ! echo "$TITLE" | grep -qi "$pattern"; then
                VALIDATION_PASSED="false"
                warn "Title missing: $pattern"
            fi
        done
    fi

    # Take screenshot
    SCREENSHOT_RESP=$(curl -s -X POST "$SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"screenshot-$STEP_ID\",\"method\":\"screenshot\",\"params\":{\"fullPage\":true}}")
    echo "$SCREENSHOT_RESP" | jq -r '.result.data // empty' | base64 -d > "$RUN_DIR/screenshots/${STEP_ID}.pdf" 2>/dev/null

    # CLIP verification
    CLIP_MATCH="1.0"
    CLIP_CORRECT="true"
    CLIP_CONFIDENCE="none"
    if [ "$CLIP_VERIFICATION" = "true" ] && [ -n "$CLIP_PROMPT" ] && [ -f "$ML_DIR/verify_product.py" ]; then
        CLIP_RESULT=$(python3 "$ML_DIR/verify_product.py" "$RUN_DIR/screenshots/${STEP_ID}.pdf" "$CLIP_PROMPT" 2>/dev/null || echo '{"is_correct":true,"match_probability":1.0,"confidence":"error"}')
        CLIP_MATCH=$(echo "$CLIP_RESULT" | jq -r '.match_probability // 1.0')
        CLIP_CORRECT=$(echo "$CLIP_RESULT" | jq -r 'if .is_correct == false then "false" else "true" end')
        CLIP_CONFIDENCE=$(echo "$CLIP_RESULT" | jq -r '.confidence // "unknown"')
        echo -e "  ${DIM}CLIP: ${CLIP_MATCH} match ($CLIP_CONFIDENCE)${NC}"
    fi

    # Extract data based on step selectors
    SELECTORS=$(echo "$STEP" | jq -c '.selectors // {}')
    EXTRACTED_DATA="{}"
    if [ "$SELECTORS" != "{}" ]; then
        for key in $(echo "$SELECTORS" | jq -r 'keys[]'); do
            selector=$(echo "$SELECTORS" | jq -r ".\"$key\"")
            EXTRACT_RESP=$(curl -s -X POST "$SERVER/command" \
                -H "Content-Type: application/json" \
                -d "{\"id\":\"extract-$STEP_ID-$key\",\"method\":\"extract\",\"params\":{\"selector\":[\"$selector\"]}}")
            value=$(echo "$EXTRACT_RESP" | jq -r '.result.value // null')
            EXTRACTED_DATA=$(echo "$EXTRACTED_DATA" | jq --arg k "$key" --arg v "$value" '. + {($k): $v}')
        done
    fi

    # Display results
    if [ "$VALIDATION_PASSED" = "true" ]; then
        success "$STEP_NAME completed"
        STEPS_COMPLETED=$((STEPS_COMPLETED + 1))
    else
        error "$STEP_NAME failed validation"
        STEPS_FAILED=$((STEPS_FAILED + 1))
    fi
    echo "  Title: $TITLE"
    echo "  Type: $PAGE_TYPE"

    # Get expected labels for this page type
    EXPECTED_LABELS=$(jq -c ".trainingLabels.\"$PAGE_TYPE\" // {}" "$WORKFLOW_FILE")

    # Generate training sample
    DOMAIN=$(echo "$CURRENT_URL" | sed -E 's|https?://([^/]+).*|\1|')

    cat > "$RUN_DIR/training/${STEP_ID}-sample.json" << TRAINING_EOF
{
  "id": "${RUN_ID}-${STEP_ID}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "workflow": "$WORKFLOW_ID",
  "step": "$STEP_ID",

  "image": {
    "path": "$RUN_DIR/screenshots/${STEP_ID}.pdf",
    "format": "pdf",
    "device": "iPhone",
    "viewport": "mobile"
  },

  "page": {
    "url": "$CURRENT_URL",
    "domain": "$DOMAIN",
    "title": "$TITLE",
    "type": "$PAGE_TYPE",
    "validationPassed": $VALIDATION_PASSED
  },

  "labels": {
    "pageType": "$PAGE_TYPE",
    "isSearchResults": $([ "$PAGE_TYPE" = "search_results" ] && echo "true" || echo "false"),
    "isProductPage": $([ "$PAGE_TYPE" = "product" ] && echo "true" || echo "false"),
    "isCartPage": $([ "$PAGE_TYPE" = "cart" ] && echo "true" || echo "false"),
    "isCheckoutPage": $([ "$PAGE_TYPE" = "checkout" ] && echo "true" || echo "false"),
    "expectedLabels": $EXPECTED_LABELS
  },

  "clipVerification": {
    "enabled": $CLIP_VERIFICATION,
    "prompt": "$CLIP_PROMPT",
    "matchProbability": $CLIP_MATCH,
    "isCorrect": $CLIP_CORRECT,
    "confidence": "$CLIP_CONFIDENCE"
  },

  "extraction": {
    "selectors": $SELECTORS,
    "data": $EXTRACTED_DATA
  },

  "outcome": {
    "stepCompleted": $VALIDATION_PASSED,
    "actionSucceeded": $(echo "$RESP" | jq -r '.success // false')
  }
}
TRAINING_EOF

    sleep 1
done

# Generate run summary
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "${BOLD}CART FLOW RESULTS${NC}"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "Steps completed: $STEPS_COMPLETED / $STEP_COUNT"
if [ $STEPS_FAILED -gt 0 ]; then
    error "Steps failed: $STEPS_FAILED"
fi

# Create manifest
SAMPLE_COUNT=$(ls -1 "$RUN_DIR/training/"*-sample.json 2>/dev/null | wc -l | tr -d ' ')

cat > "$RUN_DIR/training/manifest.json" << MANIFEST_EOF
{
  "runId": "$RUN_ID",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "workflow": "$WORKFLOW_ID",
  "store": "$STORE_NAME",
  "product": "$PRODUCT_NAME",
  "sampleCount": $SAMPLE_COUNT,
  "stepsCompleted": $STEPS_COMPLETED,
  "stepsFailed": $STEPS_FAILED,
  "pageTypes": $(ls -1 "$RUN_DIR/training/"*-sample.json 2>/dev/null | xargs -I{} cat {} | jq -s '[.[].page.type] | unique'),
  "samples": $(ls -1 "$RUN_DIR/training/"*-sample.json 2>/dev/null | xargs -I{} cat {} | jq -s '.')
}
MANIFEST_EOF

# Summary
log ""
success "Cart flow complete: $RUN_ID"
log "Screenshots: $RUN_DIR/screenshots/"
log "${CYAN}Training: $RUN_DIR/training/ ($SAMPLE_COUNT samples)${NC}"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
