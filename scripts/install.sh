#!/bin/sh
# Build a Release copy of Claude Notch and install it to /Applications.
# The first launch from /Applications turns on Start at Login (toggle it in the ✦ menu).
set -e
cd "$(dirname "$0")/.."
xcodebuild -project ClaudeNotch.xcodeproj -scheme ClaudeNotch -configuration Release \
  -derivedDataPath build/release build -quiet
pkill -x ClaudeNotch 2>/dev/null && sleep 0.5 || true
rm -rf /Applications/ClaudeNotch.app
cp -R build/release/Build/Products/Release/ClaudeNotch.app /Applications/
open /Applications/ClaudeNotch.app
echo "Installed /Applications/ClaudeNotch.app"
