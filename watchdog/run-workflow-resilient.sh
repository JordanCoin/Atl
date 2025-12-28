#!/bin/bash
# Mobile Safari Watchdog - Resilient Workflow Runner v2.0
# Supports: selector chains, fallbacks, validation, retry strategies

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
NC='\033[0m'

log() { echo -e "${BLUE}[Watchdog]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }
debug() { echo -e "${CYAN}[→]${NC}   $1"; }

# Validate input
if [ -z "$WORKFLOW_FILE" ]; then
    echo "Usage: $0 <workflow.json>"
    exit 1
fi

if [ ! -f "$WORKFLOW_FILE" ]; then
    error "Workflow file not found: $WORKFLOW_FILE"
    exit 1
fi

# Parse workflow
WORKFLOW_ID=$(jq -r '.id' "$WORKFLOW_FILE")
WORKFLOW_NAME=$(jq -r '.name' "$WORKFLOW_FILE")
WORKFLOW_VERSION=$(jq -r '.version // "1.0"' "$WORKFLOW_FILE")
PROFILE=$(jq -r '.profile // "default"' "$WORKFLOW_FILE")

# Resilience config
RETRY_COUNT=$(jq -r '.resilience.retryCount // 2' "$WORKFLOW_FILE")
CAPTURE_ON_FAILURE=$(jq -r '.resilience.captureOnFailure // true' "$WORKFLOW_FILE")
DEGRADED_IS_SUCCESS=$(jq -r '.resilience.degradedIsSuccess // true' "$WORKFLOW_FILE")

# Setup run directory
RUN_ID="${WORKFLOW_ID}-$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$RUNS_DIR/$RUN_ID"
mkdir -p "$RUN_DIR"
RESULTS_DIR="$RUN_DIR/results"
ARTIFACTS_DIR="$RUN_DIR/artifacts"
mkdir -p "$RESULTS_DIR" "$ARTIFACTS_DIR"

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Mobile Safari Watchdog v2.0 (Resilient)"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Workflow: $WORKFLOW_NAME (v$WORKFLOW_VERSION)"
log "Run ID:   $RUN_ID"
log "Profile:  $PROFILE"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check server
if ! curl -s "$SERVER/ping" | grep -q "ok"; then
    error "Server not responding at $SERVER"
    exit 1
fi
success "Server connected"

# Load profile cookies
PROFILE_COOKIES="$COOKIE_DIR/${PROFILE}.json"
if [ -f "$PROFILE_COOKIES" ]; then
    log "Loading session profile: $PROFILE"
    COOKIES=$(cat "$PROFILE_COOKIES")
    curl -s -X POST "$SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"load-cookies\",\"method\":\"setCookies\",\"params\":{\"cookies\":$COOKIES}}" > /dev/null
    success "Session loaded"
else
    warn "No saved session for profile: $PROFILE"
fi

# Initialize tracking
STEP_COUNT=$(jq '.steps | length' "$WORKFLOW_FILE")
FAILED_COUNT=0
DEGRADED_COUNT=0
FAILED_STEPS=""
DEGRADED_STEPS=""
START_TIME=$(date +%s)

# Execute each step
log ""
log "Executing $STEP_COUNT steps..."
log ""

for i in $(seq 0 $((STEP_COUNT - 1))); do
    STEP=$(jq ".steps[$i]" "$WORKFLOW_FILE")
    STEP_ID=$(echo "$STEP" | jq -r '.id')
    ACTION=$(echo "$STEP" | jq -r '.action')
    PARAMS=$(echo "$STEP" | jq -c '.params // {}')
    SAVE_AS=$(echo "$STEP" | jq -r '.saveAs // empty')
    REQUIRED=$(echo "$STEP" | jq -r '.required // true')
    TIMEOUT=$(echo "$STEP" | jq -r '.timeout // 10000')

    log "Step $((i+1))/$STEP_COUNT: $STEP_ID ($ACTION)"

    # Handle different action types
    case "$ACTION" in
        "waitForAny")
            # Wait for any selector in the list
            SELECTORS=$(echo "$STEP" | jq -c '.selectors')
            CMD_BODY=$(jq -n \
                --arg id "$STEP_ID" \
                --argjson selectors "$SELECTORS" \
                --argjson timeout "$TIMEOUT" \
                '{id: $id, method: "waitForAny", params: {selectors: $selectors, timeout: ($timeout / 1000)}}')
            ;;

        "extract")
            # Extract with selector chain
            SELECTOR=$(echo "$STEP" | jq -c '.selector')
            CMD_BODY=$(jq -n \
                --arg id "$STEP_ID" \
                --argjson selector "$SELECTOR" \
                '{id: $id, method: "extract", params: {selector: $selector}}')
            ;;

        *)
            # Standard command
            CMD_BODY=$(jq -n \
                --arg id "$STEP_ID" \
                --arg method "$ACTION" \
                --argjson params "$PARAMS" \
                '{id: $id, method: $method, params: $params}')
            ;;
    esac

    # Execute with retry logic
    ATTEMPTS=0
    SUCCESS="false"
    RESPONSE=""

    while [ "$SUCCESS" != "true" ] && [ $ATTEMPTS -lt $((RETRY_COUNT + 1)) ]; do
        ATTEMPTS=$((ATTEMPTS + 1))

        RESPONSE=$(curl -s -X POST "$SERVER/command" \
            -H "Content-Type: application/json" \
            -d "$CMD_BODY" 2>&1)

        SUCCESS=$(echo "$RESPONSE" | jq -r '.success // false')

        if [ "$SUCCESS" != "true" ] && [ $ATTEMPTS -le $RETRY_COUNT ]; then
            debug "Attempt $ATTEMPTS failed, retrying..."
            sleep 1
        fi
    done

    # Process result
    if [ "$SUCCESS" = "true" ]; then
        WAS_FALLBACK=$(echo "$RESPONSE" | jq -r '.result.wasFallback // false')
        SELECTOR_USED=$(echo "$RESPONSE" | jq -r '.result.selectorUsed // "primary"')

        if [ -n "$SAVE_AS" ]; then
            if [ "$ACTION" = "screenshot" ]; then
                echo "$RESPONSE" | jq -r '.result.data' | base64 -d > "$RUN_DIR/${SAVE_AS}.pdf"
                echo "$RUN_DIR/${SAVE_AS}.pdf" > "$RESULTS_DIR/$SAVE_AS"
                success "  → Saved: ${SAVE_AS}.pdf"
            elif [ "$ACTION" = "extract" ]; then
                VALUE=$(echo "$RESPONSE" | jq -r '.result.value // empty')
                echo "$VALUE" > "$RESULTS_DIR/$SAVE_AS"

                if [ "$WAS_FALLBACK" = "true" ]; then
                    warn "  → $SAVE_AS = $VALUE (via fallback: $SELECTOR_USED)"
                    DEGRADED_COUNT=$((DEGRADED_COUNT + 1))
                    DEGRADED_STEPS="$DEGRADED_STEPS $STEP_ID"
                else
                    success "  → $SAVE_AS = $VALUE"
                fi

                # Save extraction metadata
                echo "$RESPONSE" | jq '{selectorUsed: .result.selectorUsed, wasFallback: .result.wasFallback, attempts: .result.attempts}' > "$RESULTS_DIR/${SAVE_AS}.meta.json"
            else
                VALUE=$(echo "$RESPONSE" | jq -r '.result.value // .result // empty')
                echo "$VALUE" > "$RESULTS_DIR/$SAVE_AS"
                success "  → $SAVE_AS = $VALUE"
            fi
        else
            if [ "$ACTION" = "waitForAny" ]; then
                MATCHED=$(echo "$RESPONSE" | jq -r '.result.matched // "unknown"')
                success "  → Matched: $MATCHED"
            else
                success "  → Done"
            fi
        fi
    else
        ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error // "Unknown error"')
        error "  → Failed: $ERROR_MSG (after $ATTEMPTS attempts)"

        # Capture failure artifacts
        if [ "$CAPTURE_ON_FAILURE" = "true" ]; then
            debug "Capturing failure artifacts..."
            ARTIFACT_RESPONSE=$(curl -s -X POST "$SERVER/command" \
                -H "Content-Type: application/json" \
                -d "{\"id\":\"capture-failure\",\"method\":\"captureFailureArtifacts\",\"params\":{\"failedSelector\":\"$STEP_ID\",\"error\":\"$ERROR_MSG\"}}")

            # Save artifacts
            echo "$ARTIFACT_RESPONSE" | jq -r '.result.screenshot // empty' | base64 -d > "$ARTIFACTS_DIR/${STEP_ID}-screenshot.png" 2>/dev/null || true
            echo "$ARTIFACT_RESPONSE" | jq -r '.result.domSnapshot // empty' > "$ARTIFACTS_DIR/${STEP_ID}-dom.html" 2>/dev/null || true
            debug "Artifacts saved to $ARTIFACTS_DIR/"
        fi

        FAILED_COUNT=$((FAILED_COUNT + 1))
        FAILED_STEPS="$FAILED_STEPS $STEP_ID"

        # Exit early if required step failed
        if [ "$REQUIRED" = "true" ]; then
            error "Required step failed - aborting workflow"
            break
        fi
    fi

    sleep 0.5
done

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Save session
log ""
log "Saving session..."
COOKIES_RESPONSE=$(curl -s -X POST "$SERVER/command" \
    -H "Content-Type: application/json" \
    -d '{"id":"save-cookies","method":"getCookies","params":{}}')
echo "$COOKIES_RESPONSE" | jq '.result.cookies' > "$PROFILE_COOKIES"
success "Session saved to $PROFILE"

# Calculate run status
if [ $FAILED_COUNT -gt 0 ]; then
    RUN_STATUS="failed"
elif [ $DEGRADED_COUNT -gt 0 ]; then
    RUN_STATUS="degraded"
else
    RUN_STATUS="success"
fi

# Read extracted values
CURRENT_PRICE="null"
PRODUCT_TITLE="Unknown"
AVAILABILITY="Unknown"

[ -f "$RESULTS_DIR/currentPrice" ] && CURRENT_PRICE=$(cat "$RESULTS_DIR/currentPrice")
[ -f "$RESULTS_DIR/productTitle" ] && PRODUCT_TITLE=$(cat "$RESULTS_DIR/productTitle")
[ -f "$RESULTS_DIR/availability" ] && AVAILABILITY=$(cat "$RESULTS_DIR/availability")

# Generate report
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "RUN RESULTS"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Determine status emoji
case "$RUN_STATUS" in
    "success")  STATUS_EMOJI="✅" ;;
    "degraded") STATUS_EMOJI="⚠️" ;;
    "failed")   STATUS_EMOJI="❌" ;;
esac

REPORT_FILE="$RUN_DIR/report.json"

cat > "$REPORT_FILE" << EOF
{
  "runId": "$RUN_ID",
  "workflowId": "$WORKFLOW_ID",
  "workflowName": "$WORKFLOW_NAME",
  "version": "$WORKFLOW_VERSION",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "duration": $DURATION,
  "status": "$RUN_STATUS",
  "statusEmoji": "$STATUS_EMOJI",
  "steps": {
    "total": $STEP_COUNT,
    "success": $((STEP_COUNT - FAILED_COUNT)),
    "degraded": $DEGRADED_COUNT,
    "failed": $FAILED_COUNT
  },
  "failedSteps": "$(echo $FAILED_STEPS | xargs)",
  "degradedSteps": "$(echo $DEGRADED_STEPS | xargs)",
  "extracted": {
    "productTitle": "$PRODUCT_TITLE",
    "currentPrice": $CURRENT_PRICE,
    "availability": "$AVAILABILITY"
  },
  "resilience": {
    "retryCount": $RETRY_COUNT,
    "captureOnFailure": $CAPTURE_ON_FAILURE,
    "degradedIsSuccess": $DEGRADED_IS_SUCCESS
  },
  "artifacts": {
    "proof": "$RUN_DIR/proofPdf.pdf",
    "report": "$REPORT_FILE",
    "failureDir": "$ARTIFACTS_DIR"
  }
}
EOF

# Display results
echo ""
echo "Status:       $STATUS_EMOJI $RUN_STATUS"
echo "Product:      $PRODUCT_TITLE"
echo "Price:        \$$CURRENT_PRICE"
echo "Availability: $AVAILABILITY"
echo "Duration:     ${DURATION}s"
echo ""

if [ $DEGRADED_COUNT -gt 0 ]; then
    warn "Degraded steps (used fallbacks):$DEGRADED_STEPS"
fi

if [ $FAILED_COUNT -gt 0 ]; then
    error "Failed steps:$FAILED_STEPS"
fi

# Determine final exit status
if [ "$RUN_STATUS" = "failed" ]; then
    EXIT_CODE=1
elif [ "$RUN_STATUS" = "degraded" ] && [ "$DEGRADED_IS_SUCCESS" != "true" ]; then
    EXIT_CODE=1
else
    EXIT_CODE=0
fi

log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ $EXIT_CODE -eq 0 ]; then
    success "Run complete: $RUN_ID"
else
    error "Run failed: $RUN_ID"
fi
log "Report: $REPORT_FILE"
log "Replay: ./watchdog/run-workflow-resilient.sh $WORKFLOW_FILE"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit $EXIT_CODE
