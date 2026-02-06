#!/usr/bin/env bash
# Example: Native Contacts App - Create a Contact
# 
# This script demonstrates:
# - Opening Contacts app
# - Finding UI elements semantically
# - Filling text fields
# - Tapping buttons
# - Verifying results
#
# Requirements:
# - ATL server running with native app support
# - iOS Simulator running

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/atl-native-helper.sh"

# Test contact details
FIRST_NAME="ATL"
LAST_NAME="TestUser"
FULL_NAME="$FIRST_NAME $LAST_NAME"

echo "=== ATL Native Contacts Example ==="
echo ""
echo "Creating test contact: $FULL_NAME"
echo ""

# Step 1: Open Contacts
echo "1. Opening Contacts app..."
result=$(atl_openapp com.apple.MobileAddressBook)
success=$(echo "$result" | jq -r '.success')
if [ "$success" != "true" ]; then
  echo "   ERROR: Failed to open Contacts"
  echo "$result" | jq .
  exit 1
fi
echo "   ✓ Contacts opened"
sleep 1

# Step 2: Get initial snapshot
echo ""
echo "2. Getting contact list snapshot..."
snapshot=$(atl_snapshot --interactive)
count=$(echo "$snapshot" | jq -r '.result.count // 0')
echo "   Found $count interactive elements"

# Step 3: Tap Add button (+ icon)
echo ""
echo "3. Finding and tapping Add button..."
result=$(atl_find "Add" tap)
found=$(echo "$result" | jq -r '.result.found')
if [ "$found" != "true" ]; then
  # Try alternate labels
  result=$(atl_find "add" tap)
  found=$(echo "$result" | jq -r '.result.found')
fi
if [ "$found" = "true" ]; then
  echo "   ✓ Tapped Add"
else
  echo "   WARNING: Could not find Add button, trying snapshot for + button..."
  # Fallback: look for the + button by examining snapshot
  snapshot=$(atl_snapshot --interactive)
  plus_ref=$(echo "$snapshot" | jq -r '.result.elements[] | select(.label == "Add" or .identifier == "add") | .ref' | head -1)
  if [ -n "$plus_ref" ]; then
    atl_tapref "$plus_ref"
    echo "   ✓ Tapped Add via ref: $plus_ref"
  else
    echo "   ERROR: Cannot find Add button"
    exit 1
  fi
fi
sleep 1

# Step 4: Fill First Name
echo ""
echo "4. Filling First Name: $FIRST_NAME"
result=$(atl_find "First name" fill "$FIRST_NAME")
found=$(echo "$result" | jq -r '.result.found')
if [ "$found" = "true" ]; then
  echo "   ✓ Filled First Name"
else
  echo "   WARNING: Could not find First Name field"
  # Try alternate
  result=$(atl_find "First" fill "$FIRST_NAME")
fi
sleep 0.5

# Step 5: Fill Last Name
echo ""
echo "5. Filling Last Name: $LAST_NAME"
result=$(atl_find "Last name" fill "$LAST_NAME")
found=$(echo "$result" | jq -r '.result.found')
if [ "$found" = "true" ]; then
  echo "   ✓ Filled Last Name"
else
  echo "   WARNING: Could not find Last Name field"
  result=$(atl_find "Last" fill "$LAST_NAME")
fi
sleep 0.5

# Step 6: Take screenshot of filled form
echo ""
echo "6. Taking screenshot of form..."
SCREENSHOT_PATH="/tmp/atl-contacts-form.png"
atl_screenshot "$SCREENSHOT_PATH" > /dev/null
echo "   ✓ Screenshot saved to $SCREENSHOT_PATH"

# Step 7: Save contact (tap Done)
echo ""
echo "7. Tapping Done to save..."
result=$(atl_find "Done" tap)
found=$(echo "$result" | jq -r '.result.found')
if [ "$found" = "true" ]; then
  echo "   ✓ Tapped Done"
else
  echo "   WARNING: Could not find Done button"
  # Try Save
  result=$(atl_find "Save" tap)
fi
sleep 1

# Step 8: Verify contact was created
echo ""
echo "8. Verifying contact was created..."
result=$(atl_find "$FULL_NAME" exists)
found=$(echo "$result" | jq -r '.result.found')
if [ "$found" = "true" ]; then
  echo "   ✓ Contact '$FULL_NAME' exists!"
else
  echo "   ⚠ Could not verify contact (may still have been created)"
fi

# Step 9: Take final screenshot
echo ""
echo "9. Taking final screenshot..."
FINAL_SCREENSHOT="/tmp/atl-contacts-created.png"
atl_screenshot "$FINAL_SCREENSHOT" > /dev/null
echo "   ✓ Screenshot saved to $FINAL_SCREENSHOT"

# Step 10: Close app
echo ""
echo "10. Closing Contacts..."
atl_closeapp > /dev/null
echo "    ✓ Contacts closed"

echo ""
echo "=== Example Complete ==="
echo ""
echo "Created contact: $FULL_NAME"
echo ""
echo "Screenshots:"
echo "  Form:    $SCREENSHOT_PATH"
echo "  Final:   $FINAL_SCREENSHOT"
echo ""
echo "Note: You may want to delete this test contact manually."
