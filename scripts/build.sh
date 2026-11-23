#!/bin/zsh
# Generate the project and build Debug (or $CONFIG) into ./build.
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate --quiet
xcodebuild -project ClipboardHistory.xcodeproj -scheme ClipboardHistory -configuration "${CONFIG:-Debug}" \
  -derivedDataPath build/dd -destination 'platform=macOS' build -quiet "$@"
rm -rf build/ClipboardHistory.app && cp -R "build/dd/Build/Products/${CONFIG:-Debug}/ClipboardHistory.app" build/
echo "built build/ClipboardHistory.app"
