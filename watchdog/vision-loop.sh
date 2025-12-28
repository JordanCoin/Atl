#!/bin/bash
# Vision Loop - Claude-in-the-loop browser automation
#
# This provides primitives for vision-based automation where Claude:
# 1. Sees full-page PDFs
# 2. Decides what action to take
# 3. Executes via JS injection (only method that works for WebView)
# 4. Verifies the result
#
# Usage: Source this file, then call functions
#   source watchdog/vision-loop.sh
#   vision_init "my-workflow"
#   vision_goto "https://amazon.com"
#   vision_capture "01-homepage"
#   # Claude reads PDF, decides action
#   vision_click_text "Sign in"
#   vision_capture "02-after-click"

set -e

# ============================================================================
# Configuration
# ============================================================================
COMMAND_SERVER="${COMMAND_SERVER:-http://localhost:9222}"
VISION_BASE_DIR="${VISION_BASE_DIR:-/Users/jordan/MakersStudio/Projects/Atl/watchdog/runs}"
VISION_RUN_ID=""
VISION_RUN_DIR=""
VISION_STEP=0

# ============================================================================
# Initialization
# ============================================================================

# Initialize a new vision workflow run
# Usage: vision_init "workflow-name"
vision_init() {
    local workflow_name="${1:-vision-workflow}"
    VISION_RUN_ID="${workflow_name}-$(date +%Y%m%d-%H%M%S)"
    VISION_RUN_DIR="$VISION_BASE_DIR/$VISION_RUN_ID"
    VISION_STEP=0
    mkdir -p "$VISION_RUN_DIR"
    echo "{\"runId\":\"$VISION_RUN_ID\",\"startTime\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"workflow\":\"$workflow_name\"}" > "$VISION_RUN_DIR/manifest.json"
    echo "$VISION_RUN_DIR"
}

# Get current run directory
vision_run_dir() {
    echo "$VISION_RUN_DIR"
}

# ============================================================================
# Navigation
# ============================================================================

# Navigate to URL
# Usage: vision_goto "https://amazon.com"
vision_goto() {
    local url="$1"
    local wait="${2:-3}"
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"nav\",\"method\":\"goto\",\"params\":{\"url\":\"$url\"}}" | jq -c '{success}'
    sleep "$wait"
}

# Get current URL
vision_url() {
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d '{"id":"url","method":"evaluate","params":{"script":"window.location.href"}}' | jq -r '.result.value'
}

# Get page title
vision_title() {
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d '{"id":"title","method":"evaluate","params":{"script":"document.title"}}' | jq -r '.result.value'
}

# ============================================================================
# Vision Capture - Full Page PDFs for Claude to Read
# ============================================================================

# Capture full page PDF for Claude to analyze
# Usage: vision_capture "step-name"
# Returns: Path to saved PDF
vision_capture() {
    local name="${1:-step-$VISION_STEP}"
    VISION_STEP=$((VISION_STEP + 1))
    local step_name=$(printf "%02d-%s" $VISION_STEP "$name")

    local response=$(curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"capture\",\"method\":\"captureForVision\",\"params\":{\"savePath\":\"$VISION_RUN_DIR\",\"name\":\"$step_name\"}}")

    local pdf_path=$(echo "$response" | jq -r '.result.savedTo')
    local url=$(echo "$response" | jq -r '.result.url')
    local title=$(echo "$response" | jq -r '.result.title')

    # Output for Claude to see
    echo "{\"step\":$VISION_STEP,\"name\":\"$step_name\",\"pdf\":\"$pdf_path\",\"url\":\"$url\",\"title\":\"$title\"}"
}

# ============================================================================
# Actions - JS Injection (Only Method That Works for WebView)
# ============================================================================

# Click element by visible text (searches textContent, value, title, aria-label, name)
# Usage: vision_click_text "Add to cart"
vision_click_text() {
    local text="$1"
    cat > /tmp/vision-click.json << EOF
{"id":"click","method":"evaluate","params":{"script":"(function(){const t='$text'.toLowerCase();const els=[...document.querySelectorAll('button,a,input[type=submit],input[type=button],[role=button]')].filter(e=>(e.textContent||'').toLowerCase().includes(t)||(e.value||'').toLowerCase().includes(t)||(e.title||'').toLowerCase().includes(t)||(e.getAttribute('aria-label')||'').toLowerCase().includes(t)||(e.name||'').toLowerCase().includes(t));if(els[0]){els[0].scrollIntoView({block:'center'});els[0].click();return {success:true,element:els[0].tagName,text:els[0].textContent?.substring(0,50)||els[0].title?.substring(0,50)||''}}return {success:false,error:'not found'}})()"}}
EOF
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d @/tmp/vision-click.json | jq -c '.result.value'
}

# Click element by CSS selector
# Usage: vision_click "#add-to-cart-button"
vision_click() {
    local selector="$1"
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"click\",\"method\":\"click\",\"params\":{\"selector\":\"$selector\"}}" | jq -c '{success}'
}

# Click link containing text
# Usage: vision_click_link "View cart"
vision_click_link() {
    local text="$1"
    cat > /tmp/vision-click.json << EOF
{"id":"click","method":"evaluate","params":{"script":"(function(){const t='$text'.toLowerCase();const els=[...document.querySelectorAll('a')].filter(e=>(e.textContent||'').toLowerCase().includes(t));if(els[0]){els[0].scrollIntoView({block:'center'});els[0].click();return {success:true,href:els[0].href,text:els[0].textContent?.substring(0,50)}}return {success:false,error:'link not found'}})()"}}
EOF
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d @/tmp/vision-click.json | jq -c '.result.value'
}

# Type text into focused element or selector
# Usage: vision_type "search query" "#search-box"
vision_type() {
    local text="$1"
    local selector="${2:-}"

    if [ -n "$selector" ]; then
        # Focus the element first
        curl -s -X POST "$COMMAND_SERVER/command" \
            -H "Content-Type: application/json" \
            -d "{\"id\":\"focus\",\"method\":\"evaluate\",\"params\":{\"script\":\"document.querySelector('$selector')?.focus()\"}}" > /dev/null
    fi

    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"type\",\"method\":\"type\",\"params\":{\"text\":\"$text\"}}" | jq -c '{success}'
}

# Fill input field
# Usage: vision_fill "#search" "usb cable"
vision_fill() {
    local selector="$1"
    local value="$2"
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"fill\",\"method\":\"fill\",\"params\":{\"selector\":\"$selector\",\"value\":\"$value\"}}" | jq -c '{success}'
}

# Press key
# Usage: vision_press "Enter"
vision_press() {
    local key="$1"
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"key\",\"method\":\"press\",\"params\":{\"key\":\"$key\"}}" | jq -c '{success}'
}

# Scroll page
# Usage: vision_scroll "down" 500
vision_scroll() {
    local direction="${1:-down}"
    local amount="${2:-300}"
    local delta=$amount
    [ "$direction" = "up" ] && delta=-$amount

    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"scroll\",\"method\":\"evaluate\",\"params\":{\"script\":\"window.scrollBy(0,$delta)\"}}" | jq -c '{success:.success}'
}

# Scroll element into view
# Usage: vision_scroll_to "#product-details"
vision_scroll_to() {
    local selector="$1"
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"scroll\",\"method\":\"evaluate\",\"params\":{\"script\":\"document.querySelector('$selector')?.scrollIntoView({block:'center'})\"}}" | jq -c '{success:.success}'
}

# ============================================================================
# Page Analysis - Help Claude Understand the Page
# ============================================================================

# Get all interactive elements (buttons, links, inputs)
# Usage: vision_get_interactives
vision_get_interactives() {
    cat > /tmp/vision-query.json << 'EOF'
{"id":"query","method":"evaluate","params":{"script":"(function(){const els=[];document.querySelectorAll('button,a[href],input[type=submit],input[type=button],[role=button]').forEach((e,i)=>{if(i>30)return;const r=e.getBoundingClientRect();if(r.width===0||r.height===0)return;const t=e.textContent?.trim()||e.value||e.title||e.getAttribute('aria-label')||'';if(!t)return;els.push({tag:e.tagName,text:t.substring(0,60),type:e.type||null})});return els})()"}}
EOF
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d @/tmp/vision-query.json | jq '.result.value'
}

# Check if text exists on page
# Usage: vision_has_text "Added to cart"
vision_has_text() {
    local text="$1"
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"check\",\"method\":\"evaluate\",\"params\":{\"script\":\"document.body.textContent.toLowerCase().includes('$text'.toLowerCase())\"}}" | jq -r '.result.value'
}

# Get text content of element
# Usage: vision_get_text "#price"
vision_get_text() {
    local selector="$1"
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"text\",\"method\":\"evaluate\",\"params\":{\"script\":\"document.querySelector('$selector')?.textContent?.trim()||null\"}}" | jq -r '.result.value'
}

# Count elements matching selector
# Usage: vision_count ".product-card"
vision_count() {
    local selector="$1"
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"count\",\"method\":\"evaluate\",\"params\":{\"script\":\"document.querySelectorAll('$selector').length\"}}" | jq -r '.result.value'
}

# ============================================================================
# Set-of-Mark - Label Elements with Numbers for Claude to Reference
# ============================================================================

# Mark all interactive elements with numbered labels
# Usage: vision_mark
vision_mark() {
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d '{"id":"mark","method":"markElements","params":{}}' | jq -c '{count:.result.count}'
}

# Remove all marks
# Usage: vision_unmark
vision_unmark() {
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d '{"id":"unmark","method":"unmarkElements","params":{}}' | jq -c '{cleared:.result.cleared}'
}

# Click element by mark number
# Usage: vision_click_mark 5
vision_click_mark() {
    local label="$1"
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"click\",\"method\":\"clickMark\",\"params\":{\"label\":$label}}" | jq -c '{clicked:.result.clicked}'
}

# ============================================================================
# Workflow Completion
# ============================================================================

# Finalize workflow and save summary
# Usage: vision_complete "success" "Added item to cart"
vision_complete() {
    local status="${1:-success}"
    local message="${2:-Workflow completed}"

    local manifest="$VISION_RUN_DIR/manifest.json"
    local temp=$(mktemp)

    jq --arg status "$status" \
       --arg message "$message" \
       --arg endTime "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg steps "$VISION_STEP" \
       '. + {status:$status,message:$message,endTime:$endTime,totalSteps:($steps|tonumber)}' \
       "$manifest" > "$temp" && mv "$temp" "$manifest"

    echo "{\"runId\":\"$VISION_RUN_ID\",\"status\":\"$status\",\"steps\":$VISION_STEP,\"dir\":\"$VISION_RUN_DIR\"}"
}

# ============================================================================
# Utility
# ============================================================================

# Wait for specified seconds
# Usage: vision_wait 2
vision_wait() {
    local seconds="${1:-1}"
    sleep "$seconds"
}

# Print usage
vision_help() {
    cat << 'HELP'
Vision Loop - Claude-in-the-loop browser automation

WORKFLOW:
  vision_init "name"              Initialize workflow run
  vision_capture "step-name"      Capture PDF for Claude to read
  vision_complete "status" "msg"  Finalize workflow

NAVIGATION:
  vision_goto "url"               Navigate to URL
  vision_url                      Get current URL
  vision_title                    Get page title

ACTIONS (JS injection - only method that works for WebView):
  vision_click_text "text"        Click by visible text
  vision_click "#selector"        Click by CSS selector
  vision_click_link "text"        Click link containing text
  vision_type "text" "#input"     Type into element
  vision_fill "#input" "value"    Fill input field
  vision_press "Enter"            Press key
  vision_scroll "down" 300        Scroll page
  vision_scroll_to "#element"     Scroll element into view

ANALYSIS:
  vision_get_interactives         List clickable elements
  vision_has_text "text"          Check if text exists
  vision_get_text "#selector"     Get element text
  vision_count ".selector"        Count matching elements

SET-OF-MARK:
  vision_mark                     Label elements with numbers
  vision_unmark                   Remove labels
  vision_click_mark 5             Click element #5

EXAMPLE:
  source watchdog/vision-loop.sh
  vision_init "cart-flow"
  vision_goto "https://amazon.com/s?k=usb+cable"
  vision_capture "search-results"    # Claude reads this PDF
  vision_click_text "Add to cart"    # Claude decides this action
  vision_capture "after-add"         # Claude verifies result
  vision_goto "https://amazon.com/cart"
  vision_capture "cart"              # Claude confirms item in cart
  vision_complete "success" "Item added to cart"
HELP
}

# If run directly, show help
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    vision_help
fi
