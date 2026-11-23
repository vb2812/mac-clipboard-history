#!/bin/zsh
# Compiles the GUI-test helpers into build/tools (key, mouse, locked, axdump, promptwins).
set -e; cd "${0:A:h}/.."; mkdir -p build/tools
for f in scripts/tools/*.swift; do swiftc -O "$f" -o "build/tools/${${f:t}%.swift}"; done
ls build/tools
