#!/bin/zsh
# Build, kill any running copy, launch.
set -euo pipefail
cd "${0:A:h}/.."
./scripts/build.sh
pkill -x ClipboardHistory || true
open build/ClipboardHistory.app
