#!/usr/bin/env bash
#
# verify-bundle-recompile.sh — prove a standalone MCMonad.app can recompile a
# user config WITHOUT /nix/store. This is the end-to-end guard for the class of
# bug documented in BUGREPORT-standalone-modq-recompile.md: a bundle whose GHC
# package DB points at dead /nix/store paths (or whose C libs don't link) ships
# a Mod-q that silently does nothing.
#
# It does NOT need a /nix-free machine: it compiles a trial config with the
# bundled GHC and asserts the *output binary* has zero /nix/store references and
# actually runs. A binary with no /nix refs is self-contained by construction,
# so this is a faithful proxy for "works on a normie's Mac" while being runnable
# anywhere with Xcode Command Line Tools.
#
# Usage:
#   scripts/verify-bundle-recompile.sh [path/to/MCMonad.app]
# Defaults to ~/Applications/MCMonad.app, then /Applications/MCMonad.app.
#
# Exit 0 = self-contained recompile works. Non-zero = the bundle is broken;
# the failing check is printed. Suitable for CI (post-build) and release gating.

set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
note() { echo "  $*"; }

APP="${1:-}"
if [ -z "$APP" ]; then
  for cand in "$HOME/Applications/MCMonad.app" "/Applications/MCMonad.app"; do
    [ -d "$cand" ] && APP="$cand" && break
  done
fi
[ -n "$APP" ] && [ -d "$APP" ] || fail "MCMonad.app not found (pass its path as \$1)"
APP="${APP%/}"
CONTENTS="$APP/Contents"
GHC="$CONTENTS/MacOS/mcmonad-ghc"
PKGDB="$CONTENTS/GHC/topdir/package.conf.d"

echo "Verifying standalone recompile for: $APP"
[ -x "$GHC" ] || fail "missing bundled GHC wrapper: $GHC"
command -v otool >/dev/null 2>&1 || fail "otool not found (install Xcode Command Line Tools)"

# (1) The package DB must be /nix-free — the original silent regression.
echo "[1/4] package DB is /nix-free"
if grep -lR '/nix/store' "$PKGDB"/*.conf >/dev/null 2>&1; then
  grep -lR '/nix/store' "$PKGDB"/*.conf | sed 's/^/    still references \/nix\/store: /' >&2
  fail "package .conf files still reference /nix/store"
fi
note "ok ($(ls "$PKGDB"/*.conf 2>/dev/null | wc -l | tr -d ' ') configs, none reference /nix/store)"

# (2) Compile a trial config with the bundled GHC, from a CLEAN cwd.
# macOS's case-insensitive FS makes a cwd containing mcmonad.hs shadow the
# MCMonad library module, so compile from a scratch dir that has neither.
echo "[2/4] compile a trial config with the bundled GHC"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mcmonad-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/trial-config.hs" <<'HS'
import MCMonad
main :: IO ()
main = mcmonad defaultConfig
HS
OUT="$WORK/trial-binary"
# Run from "/" (no mcmonad.hs / MCMonad.hi to shadow the library).
if ! ( cd / && "$GHC" --make "$WORK/trial-config.hs" -o "$OUT" -v0 ) 2> "$WORK/ghc.err"; then
  echo "--- ghc output ---" >&2; cat "$WORK/ghc.err" >&2
  fail "bundled GHC could not compile a trial config"
fi
[ -x "$OUT" ] || fail "GHC reported success but produced no binary"
note "ok (compiled $WORK/trial-config.hs)"

# (3) The output binary must reference zero /nix/store dylibs — i.e. it is
# self-contained and would load on a machine that has never seen /nix.
echo "[3/4] output binary is /nix-free (self-contained)"
if otool -L "$OUT" | grep '/nix/store'; then
  fail "the recompiled binary loads dylibs from /nix/store (would break off this machine)"
fi
note "ok (all dylib load commands resolve in-bundle / system)"

# (4) The output binary actually runs — proves the @rpath/install-name wiring
# resolves the bundled C libs (X11/Xft/…) and Haskell runtime at runtime.
echo "[4/4] output binary runs (--protocol-version)"
PROTO="$("$OUT" --protocol-version 2>"$WORK/run.err")" || {
  echo "--- run output ---" >&2; cat "$WORK/run.err" >&2
  fail "the recompiled binary did not run (dyld could not resolve its dylibs)"
}
[ -n "$PROTO" ] || fail "binary ran but reported no protocol version"
BUNDLE_PROTO="$(cat "$CONTENTS/Resources/protocol-version" 2>/dev/null || echo '?')"
note "ok (config proto=$PROTO, bundle proto=$BUNDLE_PROTO)"
[ "$PROTO" = "$BUNDLE_PROTO" ] || echo "  WARN: proto mismatch — the launcher would reject this binary" >&2

echo
echo "PASS — $APP can recompile user configs standalone (no /nix/store needed)."
