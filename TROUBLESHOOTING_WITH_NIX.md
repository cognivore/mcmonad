# Troubleshooting mcmonad with Nix

## How mcmonad runs

mcmonad has two processes:

| Process | Built with | Role |
|---------|-----------|------|
| **mcmonad-core** | System Swift (Xcode) | Daemon: AX, SkyLight, hotkeys, mouse drag |
| **mcmonad** | GHC (via Nix or bundled) | Brain: StackSet, layouts, config, event loop |

They communicate over a Unix socket at `~/.config/mcmonad/core.sock`.

## Production: home-manager (recommended)

```nix
# flake.nix inputs:
mcmonad.url = "github:cognivore/mcmonad";

# In your host config:
services.mcmonad = {
  enable = true;
  configFile = ''
    import MCMonad
    main = mcmonad defaultConfig
  '';
};
```

Then:
```bash
home-manager switch --flake .#your-hostname
```

This creates a launchd agent that:
- Starts both processes on login via `mcmonad-launcher`
- Sets `MCMONAD_GHC` to a GHC with the mcmonad library (for Mod-q recompile)
- Restarts on crash (`KeepAlive = true`)
- Logs to `~/Library/Logs/mcmonad-launcher.log`

### After `home-manager switch`

```bash
# Check the agent is loaded
launchctl list | grep mcmonad

# Check processes
ps aux | grep mcmonad

# View logs
tail -f ~/Library/Logs/mcmonad-launcher.log
```

### If mcmonad doesn't start after switch

```bash
# Manually load the agent
launchctl load ~/Library/LaunchAgents/com.mcmonad.launcher.plist

# Or run the launcher directly to see errors
~/.nix-profile/bin/mcmonad-launcher --daemon
```

## Development: manual run

When iterating on mcmonad itself, you bypass home-manager and run from
the local build.

### Build

```bash
# Swift (must use system Swift, NOT Nix Swift)
cd core
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" swift build

# Haskell
cd haskell
cabal build
```

**Common Swift build failure:**
```
failed to build module 'Swift'; this SDK is not supported by the compiler
```
This means Nix's SDK is leaking into the build environment. Fix: use
`env -i` to strip the Nix environment, or exit your `nix develop` shell.

### Recompile user config

The user's `~/.config/mcmonad/mcmonad.hs` is compiled by a GHC that has
the mcmonad library in its package database. During development:

```bash
# Build a GHC with the latest library
nix build .#mcmonad-ghc

# Compile user config
result/bin/ghc --make ~/.config/mcmonad/mcmonad.hs \
    -o ~/.config/mcmonad/mcmonad-aarch64-darwin -v0
```

**Nix can't find source files:**
```
can't find source for MCMonad/Foo in src
```
Nix reads from the git index. New files must be `git add`ed before
`nix build` can see them.

### Run manually

```bash
# Kill any existing instances
pkill -9 -f mcmonad-core
pkill -9 -f mcmonad-aarch64-darwin
sleep 1

# Start core (Swift daemon)
cd ~/Github/mcmonad/core
.build/debug/mcmonad-core &

# Start brain (Haskell) with debug logging
MCMONAD_DEBUG=1 ~/.config/mcmonad/mcmonad-aarch64-darwin \
    2>/tmp/mcmonad-debug.log &

# Watch events
tail -f /tmp/mcmonad-debug.log
```

### Debug tips

```bash
# See all hotkey events
grep 'EVENT: Hotkey' /tmp/mcmonad-debug.log

# See window operations
grep 'WINDOWS:' /tmp/mcmonad-debug.log

# See frame assignments
grep 'FRAMES:' /tmp/mcmonad-debug.log

# Check system log for Swift-side messages (os_log)
log stream --predicate 'subsystem == "com.mcmonad.core"' --level debug
```

## SkyLight symbol errors

```
SkyLight missing required symbols: SLSUnregisterConnectionNotifyProc
```

The SkyLight private framework uses different symbol names across macOS
versions. mcmonad probes both names (`SLSUnregisterConnectionNotifyProc`
and `SLSRemoveConnectionNotifyProc`). If you see this error, your macOS
version uses a third name — file a bug.

## Accessibility permission

mcmonad-core requires Accessibility permission to read/write window
positions. On first launch:

**System Settings → Privacy & Security → Accessibility → add mcmonad-core**

If running from a dev build, you may need to add the specific binary path
(e.g., `.build/debug/mcmonad-core`) each time it's rebuilt.

## Common issues

### Windows don't tile / hotkeys don't work

1. Check both processes are running: `ps aux | grep mcmonad`
2. Check the socket exists: `ls ~/.config/mcmonad/core.sock`
3. Check Accessibility permission is granted
4. Run with `MCMONAD_DEBUG=1` and check for events

### Mod-q recompile fails

```
mcmonad: MCMONAD_GHC is not set.
```

Set `MCMONAD_GHC` to a GHC that has the mcmonad library:
```bash
# From home-manager (automatic)
# From dev build:
export MCMONAD_GHC=$(nix build .#mcmonad-ghc --print-out-paths)/bin/ghc
```

### Home-manager switch fails to build mcmonad

mcmonad's Nix build compiles Swift using `xcrun`, which requires Xcode
CLT. The build uses `__impureHostDeps` for `/usr/bin/codesign` and
`/usr/bin/xcrun`. If your Nix setup is sandboxed, ensure these are
accessible.

### Stale launchd agent after home-manager switch

```bash
launchctl unload ~/Library/LaunchAgents/com.mcmonad.launcher.plist
launchctl load ~/Library/LaunchAgents/com.mcmonad.launcher.plist
```

Or just log out and back in.
