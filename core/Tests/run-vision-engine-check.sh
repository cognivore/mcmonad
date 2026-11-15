#!/bin/sh
# AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).
#
# Builds and runs the real-engine check (Tests/VisionEngineCheck.swift) with
# the system toolchain, outside Nix's SDK. Run it after any change to what
# the engine is shown; it takes about a minute of CPU.
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" /usr/bin/xcrun swiftc -swift-version 6 -O \
  Sources/MCMonadCore/Index/PixelTiles.swift \
  Sources/MCMonadCore/Index/WindowPage.swift \
  Sources/MCMonadCore/Index/TextHistory.swift \
  Sources/MCMonadCore/Index/VisionReader.swift \
  Tests/VisionEngineCheck.swift \
  -o .build/vision-engine-check
.build/vision-engine-check
