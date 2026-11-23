#!/bin/zsh
# Unit tests (pass extra xcodebuild args, e.g. -only-testing:ClipboardHistoryTests/StoreTests).
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate --quiet
xcodebuild -project ClipboardHistory.xcodeproj -scheme ClipboardHistory -derivedDataPath build/dd \
  -destination 'platform=macOS' test -quiet "$@"
echo "tests passed"
