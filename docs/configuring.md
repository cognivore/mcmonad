# Configuring mcmonad

mcmonad is configured the way xmonad is: you write Haskell in
`~/.config/mcmonad/mcmonad.hs`, it compiles, and it runs. This page covers
**standalone `.app` users** — people who installed `MCMonad.app` from a release
(it lives in `~/Applications` or `/Applications`). You do **not** need Nix,
cabal, or a separately-installed GHC.

> Using **home-manager**? Manage `services.mcmonad.configFile` declaratively
> instead — these manual steps don't apply to you.

## Requirements

The one thing the bundle can't ship is Apple's linker. Compiling Haskell shells
out to `cc`/`ld`, so you need **Xcode Command Line Tools** once:

```bash
xcode-select --install
```

Everything else — GHC, the `mcmonad`/`xmonad`/`xmonad-contrib` libraries — is
inside `MCMonad.app`.

## The fast path: edit and press Mod-q

1. Edit `~/.config/mcmonad/mcmonad.hs`.
2. Press **Mod-q**.

mcmonad recompiles your config with its bundled GHC and restarts the Haskell
process; the Swift core keeps running and your windows stay put. If your config
has a **compile error**, mcmonad keeps the previous working binary — you are
never left with a dead WM. (It logs why to `~/Library/Logs/mcmonad-launcher.log`
and `~/Library/Logs/mcmonad.log`.)

A first config to copy:

```haskell
import MCMonad

main :: IO ()
main = mcmonad defaultConfig
    { mcWorkspaces = map show [1 :: Int .. 9] ++ ["0"]
    }
```

See `APP_BUNDLE_ADVANCED_CONFIG` examples for richer setups (extra workspaces,
sticky windows, scratchpads, custom keys).

## Compiling by hand (to see compiler errors directly)

```bash
APP="$HOME/Applications/MCMonad.app"   # or /Applications/MCMonad.app
ARCH=$(uname -m | sed s/arm64/aarch64/)   # aarch64 (Apple Silicon) or x86_64

# Compile from a CLEAN cwd. macOS's case-insensitive filesystem makes a cwd
# containing mcmonad.hs shadow the MCMonad library module, so compile from /tmp.
( cd /tmp && "$APP/Contents/MacOS/mcmonad-ghc" --make \
    "$HOME/.config/mcmonad/mcmonad.hs" \
    -o "$HOME/.config/mcmonad/mcmonad-$ARCH-darwin" -v0 )

# Stamp the protocol version so the launcher accepts the binary.
cp "$APP/Contents/Resources/protocol-version" \
   "$HOME/.config/mcmonad/mcmonad-$ARCH-darwin.proto"

# Reload so the launcher picks it up.
launchctl kickstart -k "gui/$(id -u)/com.mcmonad.agent" 2>/dev/null \
  || launchctl kickstart -k "gui/$(id -u)/org.nix-community.home.mcmonad"
```

If the launcher chose your binary you'll see, in
`~/Library/Logs/mcmonad-launcher.log`:

```
Using custom binary (proto v8): /Users/<you>/.config/mcmonad/mcmonad-aarch64-darwin
```

If instead you see `proto vN != bundled vM; using bundled` or `lacks protocol
stamp`, recopy the `.proto` stamp (the bundle was upgraded and bumped the IPC
protocol — just recompile and re-stamp).

## Reverting

```bash
# Back to your previous config (if you kept a backup):
cp ~/.config/mcmonad/mcmonad.hs.bak ~/.config/mcmonad/mcmonad.hs   # then Mod-q

# Back to the bundle's built-in default config entirely:
rm -f ~/.config/mcmonad/mcmonad-*-darwin ~/.config/mcmonad/mcmonad-*-darwin.proto
launchctl kickstart -k "gui/$(id -u)/com.mcmonad.agent" 2>/dev/null \
  || launchctl kickstart -k "gui/$(id -u)/org.nix-community.home.mcmonad"
```

## If recompilation doesn't work at all

The bundle ships a self-contained GHC: its package database and the C libraries
a config links (X11/Xft, pulled in by `xmonad-contrib`) are inside the `.app`,
repointed off `/nix/store`. If you suspect the bundle itself is broken (e.g. a
config that should compile won't), run the bundled verifier — it compiles a
trial config and asserts the result is self-contained and runnable:

```bash
scripts/verify-bundle-recompile.sh /path/to/MCMonad.app
```

A `PASS` means the bundle can recompile configs with no `/nix/store`. A `FAIL`
prints exactly which check broke (dead package-DB paths, a link failure, or a
dyld failure at runtime) — that's a packaging bug, not your config. This script
is also the release/CI gate (see `BUGREPORT-standalone-modq-recompile.md` for
the class of bug it guards against).

## Things to not do

- **Don't bind Mod-q to `restart`.** On recent macOS, an in-process `ghc --make`
  produces a fresh code hash and the OS revokes the Accessibility grant
  ~125 ms after exec. Recompile out-of-band (Mod-q does this for you).
- **Don't compile with a system or Homebrew GHC.** Only the bundled
  `mcmonad-ghc` has the `mcmonad` library registered. Any other GHC fails with
  `Could not find module 'MCMonad'`.
- **Don't skip the `.proto` stamp.** Without it the launcher silently keeps the
  bundled binary and your config appears to do nothing (the reason is in
  `mcmonad-launcher.log`).
- **Don't move the binary.** It must be exactly
  `~/.config/mcmonad/mcmonad-<arch>-darwin`.
