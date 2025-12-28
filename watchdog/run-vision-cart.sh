#!/bin/bash
# Vision Cart Workflow Helper
# This script provides helper functions for vision-based cart automation
# The actual decision-making is done by Claude looking at the PDFs
#
# IMPORTANT: WebView Interaction Methods
# ======================================
# WebView content is SANDBOXED from native accessibility APIs!
#
# 1. JS click via command server - ONLY METHOD THAT WORKS
#    Use: click_selector "#add-to-cart-button"
#    Requires knowing the CSS selector
#    This is the ONLY reliable way to click WebView elements
#
# 2. copy-app --press - DOES NOT WORK IN WEBVIEWS
#    Can only see native iOS UI, not WebView content
#    Use for native app buttons outside the WebView
#
# 3. Native xcodebuildmcp tap - DOES NOT WORK IN WEBVIEWS
#    Coordinate taps don't translate to WebView content
#    Use for native iOS UI only
#
# 4. JS scrollIntoView - USE FOR POSITIONING
#    Scroll elements into view before clicking:
#    evaluate "document.querySelector('#btn').scrollIntoView({block:'center'})"
#
# Vision Workflow:
#   1. captureForVision → Full page PDF (Claude sees everything)
#   2. Claude reads PDF → Identifies what page type, what to click
#   3. Claude knows common selectors OR extracts from DOM
#   4. scroll_and_click "#add-to-cart-button" (JS click)
#   5. captureForVision → Verify result
#
# The GAP: Vision sees "Add to cart" but needs selector to click
# Solutions:
#   a) Learn common selectors per site (Amazon: #add-to-cart-button)
#   b) Use Set-of-Mark to label elements with numbers
#   c) Query DOM to find selector for visible text

set -e

# Configuration
COMMAND_SERVER="http://localhost:9222"
RUN_DIR="${WATCHDOG_DIR:-/Users/jordan/MakersStudio/Projects/Atl/watchdog/runs}"
SIMULATOR_ID="${SIMULATOR_ID:-B2B56B3B-CB8C-4D6B-8F49-D587558483F5}"

# Helper function to capture full page for vision
capture_vision() {
    local run_id="$1"
    local step_name="$2"
    local save_path="$RUN_DIR/$run_id"

    mkdir -p "$save_path"

    # Call captureForVision command
    result=$(curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"capture\",\"method\":\"captureForVision\",\"params\":{\"savePath\":\"$save_path\",\"name\":\"$step_name\"}}")

    echo "$result" | jq -r '.result.savedTo'
}

# Helper function to navigate
navigate() {
    local url="$1"
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"nav\",\"method\":\"goto\",\"params\":{\"url\":\"$url\"}}" > /dev/null
    sleep 3  # Wait for page load
}

# Helper function to get current URL
get_url() {
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d '{"id":"url","method":"evaluate","params":{"script":"window.location.href"}}' | jq -r '.result.value'
}

# Helper function to get page title
get_title() {
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d '{"id":"title","method":"evaluate","params":{"script":"document.title"}}' | jq -r '.result.value'
}

# Helper function for JS click - PRIMARY METHOD FOR WEBVIEW INTERACTION
click_selector() {
    local selector="$1"
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"click\",\"method\":\"click\",\"params\":{\"selector\":\"$selector\"}}"
}

# Helper function to scroll element into view before clicking
scroll_to() {
    local selector="$1"
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"scroll\",\"method\":\"evaluate\",\"params\":{\"script\":\"document.querySelector('$selector')?.scrollIntoView({block:'center'})\"}}"
}

# Combined scroll + click (when you know the selector)
scroll_and_click() {
    local selector="$1"
    scroll_to "$selector"
    sleep 0.5
    click_selector "$selector"
}

# Find element by visible text and click it (bridges vision to action)
# Searches: textContent, value, title, aria-label, name attribute
click_by_text() {
    local text="$1"
    cat > /tmp/click-text.json << EOF
{"id":"click-text","method":"evaluate","params":{"script":"(function(){const t='$text'.toLowerCase();const els=[...document.querySelectorAll('button,a,input[type=submit],input[type=button],[role=button]')].filter(e=>(e.textContent||'').toLowerCase().includes(t)||(e.value||'').toLowerCase().includes(t)||(e.title||'').toLowerCase().includes(t)||(e.getAttribute('aria-label')||'').toLowerCase().includes(t)||(e.name||'').toLowerCase().includes(t));if(els[0]){els[0].scrollIntoView({block:'center'});els[0].click();return 'clicked '+els[0].tagName;}return 'not found';})()"}}
EOF
    curl -s -X POST "$COMMAND_SERVER/command" \
        -H "Content-Type: application/json" \
        -d @/tmp/click-text.json
}

# Print usage
usage() {
    echo "Vision Cart Workflow Helper"
    echo ""
    echo "Functions available (source this script):"
    echo "  capture_vision <run_id> <step_name>  - Capture full page PDF"
    echo "  navigate <url>                        - Navigate to URL"
    echo "  get_url                               - Get current URL"
    echo "  get_title                             - Get page title"
    echo "  click_selector <selector>             - Click element by selector"
    echo ""
    echo "Native xcodebuildmcp gestures:"
    echo "  Use mcp__xcodebuildmcp__tap, gesture, swipe directly"
    echo ""
    echo "Vision workflow loop:"
    echo "  1. capture_vision → get PDF"
    echo "  2. Claude reads PDF → decides action"
    echo "  3. Execute action (tap/swipe/click)"
    echo "  4. capture_vision → verify result"
    echo "  5. Repeat until complete"
}

# If sourced, export functions. If run directly, show usage.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    usage
fi
