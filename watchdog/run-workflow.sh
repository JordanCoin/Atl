#!/bin/bash
# Mobile Safari Watchdog - Workflow Runner
# Usage: ./run-workflow.sh <workflow.json>

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
NC='\033[0m'

log() { echo -e "${BLUE}[Watchdog]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }

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
PROFILE=$(jq -r '.profile // "default"' "$WORKFLOW_FILE")
PRICE_THRESHOLD=$(jq -r '.alertThreshold.priceBelow // 0' "$WORKFLOW_FILE")

# Setup run directory
RUN_ID="${WORKFLOW_ID}-$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$RUNS_DIR/$RUN_ID"
mkdir -p "$RUN_DIR"
RESULTS_DIR="$RUN_DIR/results"
mkdir -p "$RESULTS_DIR"

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Mobile Safari Watchdog"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Workflow: $WORKFLOW_NAME"
log "Run ID:   $RUN_ID"
log "Profile:  $PROFILE"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check server
if ! curl -s "$SERVER/ping" | grep -q "ok"; then
    error "Server not responding at $SERVER"
    exit 1
fi
success "Server connected"

# Load profile cookies if exists
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

# Initialize counters
STEP_COUNT=$(jq '.steps | length' "$WORKFLOW_FILE")
FAILED_COUNT=0
FAILED_STEPS=""
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

    log "Step $((i+1))/$STEP_COUNT: $STEP_ID ($ACTION)"

    # Build command
    CMD_BODY=$(jq -n \
        --arg id "$STEP_ID" \
        --arg method "$ACTION" \
        --argjson params "$PARAMS" \
        '{id: $id, method: $method, params: $params}')

    # Execute
    RESPONSE=$(curl -s -X POST "$SERVER/command" \
        -H "Content-Type: application/json" \
        -d "$CMD_BODY" 2>&1)

    # Check success
    SUCCESS=$(echo "$RESPONSE" | jq -r '.success // false')
    if [ "$SUCCESS" = "true" ]; then
        # Extract result if saveAs specified
        if [ -n "$SAVE_AS" ]; then
            if [ "$ACTION" = "screenshot" ]; then
                # Save screenshot to file
                echo "$RESPONSE" | jq -r '.result.data' | base64 -d > "$RUN_DIR/${SAVE_AS}.pdf"
                echo "$RUN_DIR/${SAVE_AS}.pdf" > "$RESULTS_DIR/$SAVE_AS"
                success "  → Saved: ${SAVE_AS}.pdf"
            else
                VALUE=$(echo "$RESPONSE" | jq -r '.result.value // .result // empty')
                echo "$VALUE" > "$RESULTS_DIR/$SAVE_AS"
                success "  → $SAVE_AS = $VALUE"
            fi
        else
            success "  → Done"
        fi
    else
        ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error // "Unknown error"')
        error "  → Failed: $ERROR_MSG"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        FAILED_STEPS="$FAILED_STEPS $STEP_ID"
    fi

    # Small delay between steps
    sleep 1
done

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Save session for next run
log ""
log "Saving session..."
COOKIES_RESPONSE=$(curl -s -X POST "$SERVER/command" \
    -H "Content-Type: application/json" \
    -d '{"id":"save-cookies","method":"getCookies","params":{}}')
echo "$COOKIES_RESPONSE" | jq '.result.cookies' > "$PROFILE_COOKIES"
success "Session saved to $PROFILE"

# Read extracted values
CURRENT_PRICE="null"
PRODUCT_TITLE="Unknown"
AVAILABILITY="Unknown"

[ -f "$RESULTS_DIR/currentPrice" ] && CURRENT_PRICE=$(cat "$RESULTS_DIR/currentPrice")
[ -f "$RESULTS_DIR/productTitle" ] && PRODUCT_TITLE=$(cat "$RESULTS_DIR/productTitle")
[ -f "$RESULTS_DIR/availability" ] && AVAILABILITY=$(cat "$RESULTS_DIR/availability")

# Generate run report
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "RUN RESULTS"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

REPORT_FILE="$RUN_DIR/report.json"

# Check for previous run to detect changes
PREV_RUN=$(ls -1 "$RUNS_DIR" 2>/dev/null | grep "^${WORKFLOW_ID}-" | sort | tail -2 | head -1)
PRICE_CHANGED="false"
PREV_PRICE="null"

if [ -n "$PREV_RUN" ] && [ "$PREV_RUN" != "$RUN_ID" ] && [ -f "$RUNS_DIR/$PREV_RUN/report.json" ]; then
    PREV_PRICE=$(jq -r '.extracted.currentPrice // "null"' "$RUNS_DIR/$PREV_RUN/report.json")
    if [ "$PREV_PRICE" != "$CURRENT_PRICE" ] && [ "$PREV_PRICE" != "null" ] && [ "$CURRENT_PRICE" != "null" ]; then
        PRICE_CHANGED="true"
    fi
fi

# Determine alert status
ALERT_TRIGGERED="false"
ALERT_REASON=""

if [ $FAILED_COUNT -gt 0 ]; then
    ALERT_TRIGGERED="true"
    ALERT_REASON="Workflow steps failed:$FAILED_STEPS"
elif [ "$PRICE_CHANGED" = "true" ]; then
    ALERT_TRIGGERED="true"
    ALERT_REASON="Price changed from \$$PREV_PRICE to \$$CURRENT_PRICE"
elif [ "$CURRENT_PRICE" != "null" ] && [ "$PRICE_THRESHOLD" != "0" ]; then
    if [ $(echo "$CURRENT_PRICE < $PRICE_THRESHOLD" | bc -l 2>/dev/null || echo 0) -eq 1 ]; then
        ALERT_TRIGGERED="true"
        ALERT_REASON="Price \$$CURRENT_PRICE is below threshold \$$PRICE_THRESHOLD"
    fi
fi

# Build report JSON
cat > "$REPORT_FILE" << EOF
{
  "runId": "$RUN_ID",
  "workflowId": "$WORKFLOW_ID",
  "workflowName": "$WORKFLOW_NAME",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "duration": $DURATION,
  "status": "$([ $FAILED_COUNT -eq 0 ] && echo 'success' || echo 'failed')",
  "stepsExecuted": $STEP_COUNT,
  "stepsFailed": $FAILED_COUNT,
  "failedSteps": "$(echo $FAILED_STEPS | xargs)",
  "extracted": {
    "productTitle": "$PRODUCT_TITLE",
    "currentPrice": $CURRENT_PRICE,
    "availability": "$AVAILABILITY"
  },
  "comparison": {
    "previousPrice": $PREV_PRICE,
    "priceChanged": $PRICE_CHANGED
  },
  "alert": {
    "triggered": $ALERT_TRIGGERED,
    "reason": "$ALERT_REASON",
    "threshold": $PRICE_THRESHOLD
  },
  "artifacts": {
    "proof": "$RUN_DIR/proofPdf.pdf",
    "report": "$REPORT_FILE"
  },
  "replayCommand": "./watchdog/run-workflow.sh $WORKFLOW_FILE"
}
EOF

# Display results
echo ""
echo "Product:      $PRODUCT_TITLE"
echo "Price:        \$$CURRENT_PRICE"
echo "Availability: $AVAILABILITY"
echo "Duration:     ${DURATION}s"
echo ""

if [ "$PRICE_CHANGED" = "true" ]; then
    warn "Price changed: \$$PREV_PRICE → \$$CURRENT_PRICE"
fi

if [ $FAILED_COUNT -gt 0 ]; then
    error "Failed steps:$FAILED_STEPS"
fi

if [ "$ALERT_TRIGGERED" = "true" ]; then
    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    warn "ALERT TRIGGERED"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Reason: $ALERT_REASON"
    echo ""

    # Generate Slack payload
    cat > "$RUN_DIR/slack-alert.json" << SLACK
{
  "channel": "#price-alerts",
  "username": "Mobile Safari Watchdog",
  "icon_emoji": ":dog:",
  "attachments": [
    {
      "color": "$([ $FAILED_COUNT -eq 0 ] && echo 'good' || echo 'danger')",
      "title": "$WORKFLOW_NAME",
      "text": "$ALERT_REASON",
      "fields": [
        {"title": "Product", "value": "$PRODUCT_TITLE", "short": false},
        {"title": "Current Price", "value": "\$$CURRENT_PRICE", "short": true},
        {"title": "Previous Price", "value": "\$$PREV_PRICE", "short": true},
        {"title": "Availability", "value": "$AVAILABILITY", "short": true},
        {"title": "Run ID", "value": "$RUN_ID", "short": true}
      ],
      "footer": "Mobile Safari Watchdog",
      "ts": $(date +%s)
    }
  ]
}
SLACK
    log "Slack payload saved: $RUN_DIR/slack-alert.json"
fi

log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
success "Run complete: $RUN_ID"
log "Report: $REPORT_FILE"
log "Proof:  $RUN_DIR/proofPdf.pdf"
log "Replay: ./watchdog/run-workflow.sh $WORKFLOW_FILE"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
