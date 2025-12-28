#!/bin/bash
# Atl Development Startup Script
# Usage: ./start.sh [simulator_name]

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SIMULATOR_NAME="${1:-iPhone 17}"

echo "🚀 Starting Atl Development Environment"
echo "========================================="

# 1. Find simulator UDID
echo "📱 Finding simulator: $SIMULATOR_NAME"
UDID=$(xcrun simctl list devices available | grep "$SIMULATOR_NAME" | grep -oE '[A-F0-9-]{36}' | head -1)

if [ -z "$UDID" ]; then
    echo "❌ Simulator '$SIMULATOR_NAME' not found"
    echo "Available simulators:"
    xcrun simctl list devices available | grep -E "iPhone|iPad"
    exit 1
fi
echo "   Found: $UDID"

# 2. Boot simulator if needed
echo "🔄 Booting simulator..."
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator

# 3. Build and run macOS app
echo "🖥️  Building macOS app (Atl)..."
xcodebuild -workspace "$PROJECT_DIR/Atl.xcworkspace" \
    -scheme Atl \
    -configuration Debug \
    -quiet \
    build

echo "   Launching Atl..."
MAC_APP=$(find ~/Library/Developer/Xcode/DerivedData -name "Atl.app" -path "*/Debug/*" | head -1)
open "$MAC_APP" &

# 4. Build and run iOS app
echo "📱 Building iOS app (AtlBrowser)..."
xcodebuild -workspace "$PROJECT_DIR/AtlBrowser/AtlBrowser.xcworkspace" \
    -scheme AtlBrowser \
    -configuration Debug \
    -destination "id=$UDID" \
    -quiet \
    build

echo "   Installing AtlBrowser..."
IOS_APP=$(find ~/Library/Developer/Xcode/DerivedData -name "AtlBrowser.app" -path "*Debug-iphonesimulator*" | head -1)
xcrun simctl install "$UDID" "$IOS_APP"

echo "   Launching AtlBrowser..."
xcrun simctl launch "$UDID" com.atl.browser

# 5. Wait for server
echo "⏳ Waiting for CommandServer..."
for i in {1..10}; do
    if curl -s http://localhost:9222/ping > /dev/null 2>&1; then
        echo "✅ Connected! Server responding on port 9222"
        break
    fi
    sleep 1
done

# Verify
if curl -s http://localhost:9222/ping | grep -q "ok"; then
    echo ""
    echo "========================================="
    echo "✅ Atl is ready!"
    echo ""
    echo "Test with:"
    echo "  curl http://localhost:9222/ping"
    echo ""
    echo "Or open Atl app and use Playwright Demo"
    echo "========================================="
else
    echo "⚠️  Server not responding. Try relaunching AtlBrowser."
fi
