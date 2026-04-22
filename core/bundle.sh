#!/bin/bash
# Build mcmonad-core and wrap it in a .app bundle so Carbon hotkeys work.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

swift build -c debug

APP_DIR=".build/MCMonadCore.app/Contents"
mkdir -p "$APP_DIR/MacOS"
mkdir -p "$APP_DIR/Resources"

cp .build/debug/mcmonad-core "$APP_DIR/MacOS/mcmonad-core"
cp Sources/MCMonadCore/Resources/Info.plist "$APP_DIR/Info.plist"
cp Sources/MCMonadCore/Resources/MenuBarIcon.png "$APP_DIR/Resources/MenuBarIcon.png"
cp Sources/MCMonadCore/Resources/MenuBarIcon@2x.png "$APP_DIR/Resources/MenuBarIcon@2x.png"

echo "Built: $SCRIPT_DIR/.build/MCMonadCore.app"
echo "Run:   open $SCRIPT_DIR/.build/MCMonadCore.app"
echo "  or:  $APP_DIR/MacOS/mcmonad-core"
