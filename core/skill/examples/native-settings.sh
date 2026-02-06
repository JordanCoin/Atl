#!/usr/bin/env bash
# Example: Native Settings App Navigation
# 
# This script demonstrates:
# - Opening a native iOS app (Settings)
# - Getting accessibility snapshots
# - Navigating using semantic find
# - Taking screenshots
#
# Requirements:
# - ATL server running with native app support
# - iOS Simulator running

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/atl-native-helper.sh"

echo "=== ATL Native Settings Example ==="
echo ""

# Step 1: Open Settings
echo "1. Opening Settings app..."
result=$(atl_openapp com.apple.Preferences)
success=$(echo "$result" | jq -r '.success')
if [ "$success" != "true" ]; then
  echo "   ERROR: Failed to open Settings"
  echo "$result" | jq .
  exit 1
fi
echo "   ✓ Settings opened"
sleep 1

# Step 2: Verify mode
echo ""
echo "2. Checking mode..."
mode=$(atl_mode)
echo "   Mode: $mode"
if [ "$mode" != "native" ]; then
  echo "   WARNING: Expected native mode"
fi

# Step 3: Get snapshot
echo ""
echo "3. Getting accessibility snapshot..."
snapshot=$(atl_snapshot --interactive)
count=$(echo "$snapshot" | jq -r '.result.count // 0')
echo "   Found $count interactive elements"

# Show first few elements
echo "   Sample elements:"
echo "$snapshot" | jq -r '.result.elements[:5][] | "     \(.ref): \(.type) - \(.label // .identifier // "no label")"' 2>/dev/null || true

# Step 4: Navigate to Wi-Fi
echo ""
echo "4. Finding and tapping Wi-Fi..."
result=$(atl_find "Wi-Fi" tap)
found=$(echo "$result" | jq -r '.result.found')
if [ "$found" = "true" ]; then
  echo "   ✓ Tapped Wi-Fi"
else
  echo "   Could not find Wi-Fi, trying WLAN..."
  result=$(atl_find "WLAN" tap)
  found=$(echo "$result" | jq -r '.result.found')
  if [ "$found" = "true" ]; then
    echo "   ✓ Tapped WLAN"
  else
    echo "   WARNING: Could not find Wi-Fi/WLAN"
  fi
fi
sleep 1

# Step 5: Take screenshot
echo ""
echo "5. Taking screenshot..."
SCREENSHOT_PATH="/tmp/atl-settings-wifi.png"
atl_screenshot "$SCREENSHOT_PATH" > /dev/null
echo "   ✓ Screenshot saved to $SCREENSHOT_PATH"

# Step 6: Get Wi-Fi screen snapshot
echo ""
echo "6. Getting Wi-Fi screen snapshot..."
snapshot=$(atl_snapshot --interactive)
count=$(echo "$snapshot" | jq -r '.result.count // 0')
echo "   Found $count elements on Wi-Fi screen"

# Step 7: Navigate back
echo ""
echo "7. Navigating back (swipe right)..."
atl_swipe right
sleep 0.5
echo "   ✓ Swiped back"

# Step 8: Close app
echo ""
echo "8. Closing Settings..."
atl_closeapp > /dev/null
echo "   ✓ Settings closed"

echo ""
echo "=== Example Complete ==="
echo ""
echo "Outputs:"
echo "  Screenshot: $SCREENSHOT_PATH"
echo ""
echo "Try opening the screenshot:"
echo "  open $SCREENSHOT_PATH"
