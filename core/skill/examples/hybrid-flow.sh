#!/usr/bin/env bash
# Example: Hybrid Browser + Native App Flow
# 
# This script demonstrates:
# - Starting in browser mode
# - Switching to native app (Settings)
# - Switching back to browser
# - Mode verification at each step
#
# This is the core "hybrid" pattern for workflows that need both web and native.
#
# Requirements:
# - ATL server running with native app support
# - iOS Simulator running

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/atl-native-helper.sh"

echo "=== ATL Hybrid Flow Example ==="
echo ""
echo "This demonstrates switching between browser and native app modes."
echo ""

# Step 1: Start with browser
echo "1. Starting in browser mode..."
echo "   Navigating to example.com..."
result=$(atl_goto "https://example.com")
success=$(echo "$result" | jq -r '.success')
if [ "$success" != "true" ]; then
  echo "   WARNING: goto returned non-success, checking mode anyway..."
fi
sleep 2

mode=$(atl_mode)
echo "   Current mode: $mode"
if [ "$mode" = "browser" ]; then
  echo "   ✓ Browser mode confirmed"
else
  echo "   Note: Mode is '$mode' (expected 'browser')"
fi

# Step 2: Take browser screenshot
echo ""
echo "2. Taking browser screenshot..."
BROWSER_SCREENSHOT="/tmp/atl-hybrid-browser.png"
atl_screenshot "$BROWSER_SCREENSHOT" > /dev/null
echo "   ✓ Saved to $BROWSER_SCREENSHOT"

# Step 3: Switch to native Settings
echo ""
echo "3. Switching to native app (Settings)..."
result=$(atl_openapp com.apple.Preferences)
success=$(echo "$result" | jq -r '.success')
if [ "$success" = "true" ]; then
  echo "   ✓ Settings app opened"
else
  echo "   ERROR: Failed to open Settings"
  echo "$result" | jq .
  exit 1
fi
sleep 1

mode=$(atl_mode)
echo "   Current mode: $mode"
if [ "$mode" = "native" ]; then
  echo "   ✓ Native mode confirmed"
fi

# Step 4: Interact with native app
echo ""
echo "4. Interacting with Settings..."
snapshot=$(atl_snapshot --interactive)
count=$(echo "$snapshot" | jq -r '.result.count // 0')
echo "   Found $count interactive elements"

# Try to find General
result=$(atl_find "General" tap)
found=$(echo "$result" | jq -r '.result.found')
if [ "$found" = "true" ]; then
  echo "   ✓ Tapped 'General'"
  sleep 1
else
  echo "   Note: Could not find 'General' (might need to scroll)"
fi

# Step 5: Take native screenshot
echo ""
echo "5. Taking native screenshot..."
NATIVE_SCREENSHOT="/tmp/atl-hybrid-native.png"
atl_screenshot "$NATIVE_SCREENSHOT" > /dev/null
echo "   ✓ Saved to $NATIVE_SCREENSHOT"

# Step 6: Switch back to browser
echo ""
echo "6. Switching back to browser..."
result=$(atl_openbrowser)
success=$(echo "$result" | jq -r '.success')
if [ "$success" = "true" ]; then
  echo "   ✓ Browser mode activated"
else
  echo "   Note: openBrowser returned:"
  echo "$result" | jq .
fi
sleep 1

mode=$(atl_mode)
echo "   Current mode: $mode"
if [ "$mode" = "browser" ]; then
  echo "   ✓ Browser mode confirmed"
fi

# Step 7: Verify browser state
echo ""
echo "7. Verifying browser state..."
# Try to get URL or take screenshot
FINAL_SCREENSHOT="/tmp/atl-hybrid-final.png"
atl_screenshot "$FINAL_SCREENSHOT" > /dev/null
echo "   ✓ Screenshot saved to $FINAL_SCREENSHOT"

# Step 8: Show app state summary
echo ""
echo "8. Final state check..."
state=$(atl_appstate)
echo "   App state:"
echo "$state" | jq '.result'

echo ""
echo "=== Example Complete ==="
echo ""
echo "Mode transitions:"
echo "  browser → native → browser"
echo ""
echo "Screenshots captured:"
echo "  Browser: $BROWSER_SCREENSHOT"
echo "  Native:  $NATIVE_SCREENSHOT"
echo "  Final:   $FINAL_SCREENSHOT"
echo ""
echo "Compare the screenshots to see the mode switches:"
echo "  open $BROWSER_SCREENSHOT $NATIVE_SCREENSHOT $FINAL_SCREENSHOT"
echo ""
echo "Key pattern: Use atl_openapp to switch to native, atl_openbrowser to return."
