#!/bin/bash
# AI-generated file: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).
#
# The only build: Rust (core tests, staticlib, guard) -> generated bindings -> Swift lint ->
# SwiftPM -> bundle -> Developer ID signature, inside-out -> selftest. `--install` then
# puts the app at ~/Applications/Awake.app, the stable path macOS remembers the guard by.
set -euo pipefail
cd "$(dirname "$0")"
app=build/Awake.app
identity=${SIGN_IDENTITY:-"Developer ID Application: Emils Petracenoks (22GNLKBRMV)"}

# 1. Rust, in the flake's shell. Bindings come from the library just built.
nix develop . -c bash -euo pipefail -c '
  if grep -rnE "extern crate std|\bunsafe\b" core/src || ! grep -q "^#!\[cfg_attr(not(test), no_std)\]" core/src/lib.rs; then
    echo "purity: the core stays no_std, without unsafe" >&2; exit 1; fi
  if cargo tree -p awake_core -e normal --prefix none | grep -E "^(tokio|uniffi|libc) "; then
    echo "purity: the core depends on an effectful crate" >&2; exit 1; fi
  cargo test -q
  cargo clippy -q --all-targets -- -D warnings
  export MACOSX_DEPLOYMENT_TARGET=14.0
  cargo build -q --release -p awake_ffi -p awake-guard
  gen() { cargo run -q -p uniffi-bindgen-swift -- target/release/libawake_ffi.a "$@"; }
  rm -rf host/Sources/AwakeFFI host/Sources/awake_ffiFFI
  gen host/Sources/AwakeFFI --swift-sources
  gen host/Sources/awake_ffiFFI --headers
  gen host/Sources/awake_ffiFFI --modulemap --module-name awake_ffiFFI --modulemap-filename module.modulemap
'

# 2. Swift owns platform readings and the menu only.
src=host/Sources/Awake
if /usr/bin/grep -nE 'URLSession|import Network|Process\(|NSTask|posix_spawn|Data\(contentsOf:|\.write\(to:|FileManager|FileHandle|JSONDecoder|JSONEncoder|Codable|NSLog|os_log|Logger\(|UserDefaults|@AppStorage|\bTimer\b|dlsym|@_silgen_name' "$src"/*.swift; then
  echo "swift-lint: subprocesses, files, JSON, logging, timers and state belong to Rust" >&2
  exit 1
fi
lines=$(cat "$src"/*.swift | wc -l)
[ "$lines" -le 400 ] || { echo "swift-lint: $lines lines > 400; move logic to Rust" >&2; exit 1; }

# 3. Swift with the system Xcode, never the devshell's SDK.
rm -f host/.build/release/Awake # SwiftPM does not notice a rebuilt .a
env -u SDKROOT -u DEVELOPER_DIR /usr/bin/xcrun swift build -q -c release --package-path host

# 4. Bundle; sign inside-out (guard, then app) with the hardened runtime; verify.
rm -rf "$app" && mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/LaunchDaemons"
cp host/.build/release/Awake "$app/Contents/MacOS/Awake"
cp target/release/awake-guard "$app/Contents/MacOS/awake-guard"
cp host/Info.plist "$app/Contents/Info.plist"
cp host/de.memorici.awake.guard.plist "$app/Contents/Library/LaunchDaemons/"
/usr/bin/plutil -lint "$app/Contents/Info.plist" "$app/Contents/Library/LaunchDaemons/de.memorici.awake.guard.plist" >/dev/null
/usr/bin/codesign --force --options runtime --timestamp --identifier de.memorici.awake.guard --sign "$identity" "$app/Contents/MacOS/awake-guard"
/usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$app"
/usr/bin/codesign --verify --deep --strict "$app"

# 5. Selftest the binary inside the bundle.
"$app/Contents/MacOS/Awake" --selftest

# 6. Install at the stable path, and restart the running copy.
if [ "${1:-}" = "--install" ]; then
  /usr/bin/pkill -x Awake || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Awake.app"
  cp -R "$app" "$HOME/Applications/Awake.app"
  /usr/bin/open "$HOME/Applications/Awake.app"
  echo "installed $HOME/Applications/Awake.app"
fi
