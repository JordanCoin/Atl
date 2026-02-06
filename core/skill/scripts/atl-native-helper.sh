#!/usr/bin/env bash
# ATL Native App Helper Functions
# Source this file to get helper functions for native iOS app automation
#
# Requires: ATL server running on localhost:9222 with native app support
# Usage: source atl-native-helper.sh

ATL_URL="${ATL_URL:-http://localhost:9222}"
ATL_NATIVE_URL="${ATL_NATIVE_URL:-http://localhost:9223}"

# ============================================================================
# Core Helper
# ============================================================================

_atl_cmd() {
  local method="$1"
  shift
  local params=""
  if [ $# -gt 0 ]; then
    params=",\"params\":{$*}"
  fi
  curl -s -X POST "$ATL_URL/command" \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"$(date +%s%N)\",\"method\":\"$method\"$params}"
}

# Native commands use the UI Test server on port 9223
_atl_native_cmd() {
  local method="$1"
  shift
  local params=""
  if [ $# -gt 0 ]; then
    params=",\"params\":{$*}"
  fi
  curl -s -X POST "$ATL_NATIVE_URL/command" \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"$(date +%s%N)\",\"method\":\"$method\"$params}"
}

# ============================================================================
# Native App Commands
# ============================================================================

# Open a native app by bundle ID
# Usage: atl_openapp com.apple.Preferences
atl_openapp() {
  local bundle_id="$1"
  if [ -z "$bundle_id" ]; then
    echo "Usage: atl_openapp <bundleId>" >&2
    echo "Example: atl_openapp com.apple.Preferences" >&2
    return 1
  fi
  _atl_native_cmd "openApp" "\"bundleId\":\"$bundle_id\""
}

# Close the current app (returns to springboard/previous state)
# Usage: atl_closeapp
atl_closeapp() {
  _atl_native_cmd "closeApp"
}

# Get accessibility snapshot of current native app UI
# Usage: atl_snapshot [--interactive]
#   --interactive: Only return hittable elements
atl_snapshot() {
  local interactive_only="false"
  if [ "$1" = "--interactive" ] || [ "$1" = "-i" ]; then
    interactive_only="true"
  fi
  _atl_native_cmd "snapshot" "\"interactiveOnly\":$interactive_only"
}

# Tap an element by its ref (from snapshot)
# Usage: atl_tapref e5
atl_tapref() {
  local ref="$1"
  if [ -z "$ref" ]; then
    echo "Usage: atl_tapref <ref>" >&2
    echo "Example: atl_tapref e5" >&2
    return 1
  fi
  _atl_native_cmd "tapRef" "\"ref\":\"$ref\""
}

# Semantic find - find element by text and optionally act on it
# Usage: atl_find <text> [action] [value]
#   Actions: tap, fill, exists, get
#   Example: atl_find "Wi-Fi" tap
#   Example: atl_find "First name" fill "John"
#   Example: atl_find "Done" exists
atl_find() {
  local text="$1"
  local action="${2:-exists}"
  local value="$3"
  
  if [ -z "$text" ]; then
    echo "Usage: atl_find <text> [tap|fill|exists|get] [value]" >&2
    echo "Examples:" >&2
    echo "  atl_find 'Wi-Fi' tap         # Find and tap Wi-Fi" >&2
    echo "  atl_find 'First name' fill 'John'  # Fill a text field" >&2
    echo "  atl_find 'Done' exists       # Check if Done button exists" >&2
    echo "  atl_find 'Settings' get      # Get element info" >&2
    return 1
  fi
  
  local params="\"text\":\"$text\",\"action\":\"$action\""
  if [ -n "$value" ]; then
    params="$params,\"value\":\"$value\""
  fi
  
  _atl_native_cmd "find" "$params"
}

# Show current automation mode (browser or native)
# Usage: atl_mode
atl_mode() {
  _atl_native_cmd "appState" | jq -r '.result.mode // "unknown"'
}

# Get full app state (mode + bundleId if in native mode)
# Usage: atl_appstate
atl_appstate() {
  _atl_native_cmd "appState"
}

# ============================================================================
# Browser Mode Commands (for hybrid workflows)
# ============================================================================

# Switch back to browser mode from native mode
# Usage: atl_openbrowser
atl_openbrowser() {
  _atl_cmd "openBrowser"
}

# Navigate browser to URL (switches to browser mode)
# Usage: atl_goto https://example.com
atl_goto() {
  local url="$1"
  if [ -z "$url" ]; then
    echo "Usage: atl_goto <url>" >&2
    return 1
  fi
  _atl_cmd "goto" "\"url\":\"$url\""
}

# ============================================================================
# Universal Commands (Browser - port 9222)
# ============================================================================

# Tap at coordinates (browser)
# Usage: atl_tap 200 300
atl_tap() {
  local x="$1"
  local y="$2"
  if [ -z "$x" ] || [ -z "$y" ]; then
    echo "Usage: atl_tap <x> <y>" >&2
    return 1
  fi
  _atl_cmd "tap" "\"x\":$x,\"y\":$y"
}

# Swipe in a direction (browser)
# Usage: atl_swipe up|down|left|right [distance]
atl_swipe() {
  local direction="$1"
  local distance="${2:-300}"
  if [ -z "$direction" ]; then
    echo "Usage: atl_swipe <up|down|left|right> [distance]" >&2
    return 1
  fi
  _atl_cmd "swipe" "\"direction\":\"$direction\",\"distance\":$distance"
}

# Take screenshot (browser - returns base64 PNG)
# Usage: atl_screenshot [output_file]
atl_screenshot() {
  local outfile="$1"
  local result
  result=$(_atl_cmd "screenshot")
  
  if [ -n "$outfile" ]; then
    echo "$result" | jq -r '.result.data' | base64 -d > "$outfile"
    echo "$outfile"
  else
    echo "$result"
  fi
}

# ============================================================================
# Universal Commands (Native - port 9223)
# ============================================================================

# Tap at coordinates (native)
# Usage: atl_native_tap 200 300
atl_native_tap() {
  local x="$1"
  local y="$2"
  if [ -z "$x" ] || [ -z "$y" ]; then
    echo "Usage: atl_native_tap <x> <y>" >&2
    return 1
  fi
  _atl_native_cmd "tap" "\"x\":$x,\"y\":$y"
}

# Swipe in a direction (native)
# Usage: atl_native_swipe up|down|left|right
atl_native_swipe() {
  local direction="$1"
  if [ -z "$direction" ]; then
    echo "Usage: atl_native_swipe <up|down|left|right>" >&2
    return 1
  fi
  _atl_native_cmd "swipe" "\"direction\":\"$direction\""
}

# Take screenshot (native - returns base64 PNG)
# Usage: atl_native_screenshot [output_file]
atl_native_screenshot() {
  local outfile="$1"
  local result
  result=$(_atl_native_cmd "screenshot")
  
  if [ -n "$outfile" ]; then
    echo "$result" | jq -r '.result.data' | base64 -d > "$outfile"
    echo "$outfile"
  else
    echo "$result"
  fi
}

# ============================================================================
# Convenience Aliases
# ============================================================================

# Common bundle IDs
ATL_SETTINGS="com.apple.Preferences"
ATL_CONTACTS="com.apple.MobileAddressBook"
ATL_CALCULATOR="com.apple.calculator"
ATL_CALENDAR="com.apple.mobilecal"
ATL_NOTES="com.apple.mobilenotes"
ATL_REMINDERS="com.apple.reminders"
ATL_MAPS="com.apple.Maps"
ATL_PHOTOS="com.apple.mobileslideshow"
ATL_SAFARI="com.apple.mobilesafari"
ATL_FILES="com.apple.DocumentsApp"
ATL_CLOCK="com.apple.mobiletimer"
ATL_WEATHER="com.apple.weather"

# Quick open common apps
atl_open_settings() { atl_openapp "$ATL_SETTINGS"; }
atl_open_contacts() { atl_openapp "$ATL_CONTACTS"; }
atl_open_calculator() { atl_openapp "$ATL_CALCULATOR"; }
atl_open_notes() { atl_openapp "$ATL_NOTES"; }

# ============================================================================
# Usage Help
# ============================================================================

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cat << 'EOF'
ATL Native App Helper Functions

SETUP:
  source atl-native-helper.sh

NATIVE APP COMMANDS:
  atl_openapp <bundleId>      Open a native app
  atl_closeapp                Close current app
  atl_snapshot [--interactive] Get accessibility snapshot
  atl_tapref <ref>            Tap element by ref (e.g., e5)
  atl_find <text> [action] [value]  Semantic find and act
  atl_mode                    Show current mode (browser/native)
  atl_appstate                Get full app state

BROWSER COMMANDS:
  atl_openbrowser             Switch back to browser mode
  atl_goto <url>              Navigate to URL

UNIVERSAL COMMANDS (both modes):
  atl_tap <x> <y>             Tap at coordinates
  atl_swipe <direction> [dist] Swipe up/down/left/right
  atl_screenshot [file]       Take screenshot

COMMON BUNDLE IDs:
  Settings:    com.apple.Preferences
  Contacts:    com.apple.MobileAddressBook
  Calculator:  com.apple.calculator
  Calendar:    com.apple.mobilecal
  Notes:       com.apple.mobilenotes
  Safari:      com.apple.mobilesafari

QUICK OPEN:
  atl_open_settings           Open Settings app
  atl_open_contacts           Open Contacts app
  atl_open_calculator         Open Calculator app
  atl_open_notes              Open Notes app

EXAMPLE WORKFLOW:
  source atl-native-helper.sh
  
  # Open Settings and navigate
  atl_openapp com.apple.Preferences
  sleep 1
  atl_find "Wi-Fi" tap
  sleep 1
  atl_screenshot /tmp/wifi.png
  
  # Switch to browser
  atl_goto "https://example.com"
  echo "Mode: $(atl_mode)"
  
  # Back to native
  atl_openapp com.apple.Preferences
EOF
fi
