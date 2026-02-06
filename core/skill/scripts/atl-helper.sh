#!/usr/bin/env bash
# ATL helper functions for OpenClaw
# Source this or use individual functions

ATL_URL="${ATL_URL:-http://localhost:9222}"

atl_ping() {
  curl -s "$ATL_URL/ping" | jq -e '.status == "ok"' >/dev/null 2>&1
}

atl_cmd() {
  local method="$1"
  shift
  local params=""
  if [ $# -gt 0 ]; then
    params=",\"params\":{$*}"
  fi
  curl -s -X POST "$ATL_URL/command" \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"$(date +%s)\",\"method\":\"$method\"$params}"
}

atl_goto() {
  atl_cmd "goto" "\"url\":\"$1\""
}

atl_mark() {
  atl_cmd "markAll"
}

atl_click() {
  atl_cmd "clickMark" "\"label\":$1"
}

atl_type() {
  atl_cmd "type" "\"text\":\"$1\""
}

atl_press() {
  atl_cmd "press" "\"key\":\"$1\""
}

atl_screenshot() {
  local outfile="${1:-screenshot.png}"
  local fullpage="${2:-false}"
  if [ "$fullpage" = "true" ]; then
    atl_cmd "screenshot" "\"fullPage\":true" | jq -r '.result.data' | base64 -d > "$outfile"
  else
    atl_cmd "screenshot" | jq -r '.result.data' | base64 -d > "$outfile"
  fi
  echo "$outfile"
}

atl_find() {
  # Find element by text (case insensitive), return label
  local text="$1"
  atl_cmd "markAll" | jq -r "[.result.elements[] | select(.text | test(\"$text\";\"i\"))][0].label"
}

atl_info() {
  # Get element info by label (returns x, y, width, height, text, tag)
  local label="$1"
  atl_cmd "getMarkInfo" "\"label\":$label" | jq '.result'
}

atl_coords() {
  # Get just x,y coordinates for a label (for tap/gesture use)
  local label="$1"
  atl_cmd "getMarkInfo" "\"label\":$label" | jq -r '"\(.result.x) \(.result.y)"'
}

atl_capture_pdf() {
  # Capture page as PDF with text layer (machine-readable)
  local outdir="${1:-/tmp}"
  local name="${2:-atl-capture}"
  atl_cmd "captureForVision" "\"savePath\":\"$outdir\",\"name\":\"$name\"" | jq -r '.result.path'
}

atl_tap() {
  atl_cmd "tap" "\"x\":$1,\"y\":$2"
}

atl_longpress() {
  local duration="${3:-0.5}"
  atl_cmd "longPress" "\"x\":$1,\"y\":$2,\"duration\":$duration"
}

atl_swipe() {
  local direction="$1"
  local distance="${2:-300}"
  atl_cmd "swipe" "\"direction\":\"$direction\",\"distance\":$distance"
}

atl_swipe_coords() {
  atl_cmd "swipe" "\"fromX\":$1,\"fromY\":$2,\"toX\":$3,\"toY\":$4"
}

atl_pinch() {
  local scale="${1:-1.5}"
  atl_cmd "pinch" "\"scale\":$scale"
}

# If run directly, show usage
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "ATL Helper - source this file or use functions directly"
  echo ""
  echo "Navigation:"
  echo "  atl_ping              - Check if ATL is running"
  echo "  atl_goto <url>        - Navigate to URL"
  echo ""
  echo "Element Discovery (vision-free!):"
  echo "  atl_mark              - Mark all elements (returns JSON)"
  echo "  atl_find <text>       - Find element label by text"
  echo "  atl_info <label>      - Get element info (x, y, width, height, text)"
  echo "  atl_coords <label>    - Get just x,y for a label"
  echo ""
  echo "Interactions:"
  echo "  atl_click <label>     - Click element by label number"
  echo "  atl_type <text>       - Type text into focused element"
  echo "  atl_press <key>       - Press key (Enter, Tab, etc.)"
  echo ""
  echo "Touch Gestures (use with atl_coords!):"
  echo "  atl_tap <x> <y>       - Tap at coordinates"
  echo "  atl_longpress <x> <y> [duration] - Long press"
  echo "  atl_swipe <direction> [distance] - Swipe up/down/left/right"
  echo "  atl_swipe_coords <x1> <y1> <x2> <y2> - Swipe between points"
  echo "  atl_pinch [scale]     - Pinch zoom (>1 = zoom in)"
  echo ""
  echo "Capture:"
  echo "  atl_screenshot [file] [fullpage] - Take screenshot (PNG)"
  echo "  atl_capture_pdf [dir] [name]     - PDF with text layer"
  echo ""
  echo "Vision-Free Workflow:"
  echo "  atl_goto 'https://shop.example.com'"
  echo "  atl_mark                          # Mark elements"
  echo "  LABEL=\$(atl_find 'Add to Cart')  # Find by text"
  echo "  read X Y <<< \$(atl_coords \$LABEL) # Get coordinates"
  echo "  atl_tap \$X \$Y                    # Tap at exact position"
  echo "  atl_swipe up                      # Scroll down"
fi
