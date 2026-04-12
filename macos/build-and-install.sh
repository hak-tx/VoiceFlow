#!/bin/bash
set -e

echo "Building VoiceFlowMac..."
cd "$(dirname "$0")"

# Clean
rm -rf build/

# Build release
xcodebuild \
    -project VoiceFlowMac.xcodeproj \
    -scheme VoiceFlowMac \
    -configuration Release \
    -derivedDataPath build/derived \
    build 2>&1 | tail -5

# Find the built app
APP=$(find build/derived -name "VoiceFlowMac.app" -type d | head -1)

if [ -z "$APP" ]; then
    echo "ERROR: Build failed - no .app found"
    exit 1
fi

# Kill any running instance
killall -9 VoiceFlowMac 2>/dev/null || true

# Install to /Applications
echo "Installing to /Applications..."
rm -rf /Applications/VoiceFlowMac.app
cp -R "$APP" /Applications/VoiceFlowMac.app

echo ""
echo "Installed to /Applications/VoiceFlowMac.app"
echo ""
echo "First time setup:"
echo "  1. Open the app from /Applications (NOT Xcode)"
echo "  2. Grant Accessibility when prompted"
echo "  3. Grant Speech Recognition when prompted"
echo "  4. Double-tap Control to dictate"
echo ""
echo "Launching..."
open /Applications/VoiceFlowMac.app
