# Advanced configuration on the McMonad `.app` bundle

How to replace the bundle's default config with your own compiled
`mcmonad.hs` — extra workspaces, custom keys, scratchpads, sticky
windows — without ever installing Nix, Haskell, or GHC by hand.

This is the procedure for users who installed McMonad from a release
`.dmg`/`.zip` (i.e. `MCMonad.app` lives in `~/Applications` or
`/Applications`). If you installed via `home-manager`, manage
`services.mcmonad.configFile` declaratively instead — these steps do
not apply to you.

---

## How the bundle finds your config

`MCMonad.app/Contents/MacOS/mcmonad-launcher` is what launchd actually
runs. Every time it starts a Haskell process it does two things:

1. **Picks a GHC.** If `$MCMONAD_GHC` is not already set, the launcher
   exports `MCMONAD_GHC=$APP_DIR/MacOS/mcmonad-ghc` — a wrapper around
   the GHC bundled in `MCMonad.app/Contents/GHC/` that already has the
   `mcmonad` library in its package DB. You do **not** need to install
   GHC, cabal, stack, or Nix.
2. **Picks a binary.** It checks for a user-compiled binary at:

   ```
   ~/.config/mcmonad/mcmonad-<arch>-darwin
   ```

   where `<arch>` is `aarch64` on Apple Silicon and `x86_64` on Intel.
   If that file exists **and** its `.proto` sidecar matches the
   bundle's protocol version, the launcher runs it instead of the
   bundled default. Otherwise it silently falls back to the default
   and logs the reason to `~/Library/Logs/mcmonad-launcher.log`.

So "install a custom config" means: write `mcmonad.hs`, compile it to
that exact path with the bundled GHC, and reload the launchd agent.

---

## Step 1 — create `~/.config/mcmonad/mcmonad.hs`

```bash
mkdir -p ~/.config/mcmonad
```

Open `~/.config/mcmonad/mcmonad.hs` in your editor and paste the
config below. This is the configuration you asked to copy — 22
workspaces (1–9, 0, plus `a z x c v b y u i o n m`), `ThreeColMid` as
the primary layout, a sticky-window toggle on `Opt-s`, a maximize/
unmaximize toggle on `Opt-f`, and a Ghostty dropdown scratchpad on
`Opt-d`.

```haskell
import MCMonad
import MCMonad.Config.Keys
import MCMonad.Compat.XMonadContrib (XMonadWrapper(..))
import qualified XMonad.Layout.ThreeColumns as XMonad
import qualified Data.Map.Strict as Map
import Data.Bits ((.|.))

main :: IO ()
main = mcmonad defaultConfig
    { layoutHook = Layout (XW (XMonad.ThreeColMid 1 0.03 (1/3))
                       ||| Tall 1 0.03 0.5
                       ||| Full)
    , mcWorkspaces = numWs ++ extraWs
    , mcKeys = myKeys
    , mouseWarping = False
    }

numWs :: [String]
numWs = map show [1 :: Int .. 9] ++ ["0"]

extraWs :: [String]
extraWs = ["a", "z", "x", "c", "v", "b", "y", "u", "i", "o", "n", "m"]

extraWsKeys :: [(String, KeyCode)]
extraWsKeys =
    [ ("a", kA), ("z", kZ), ("x", kX), ("c", kC)
    , ("v", kV), ("b", kB)
    , ("y", kY), ("u", kU), ("i", kI), ("o", kO)
    , ("n", kN), ("m", kM)
    ]

myKeys :: MConfig Layout -> Map.Map (Modifiers, KeyCode) (M ())
myKeys conf =
    Map.fromList extras `Map.union` defaultKeys conf
  where
    m = modMask conf
    extras =
        [ ((m, key),                   windows (greedyView ws))
        | (ws, key) <- extraWsKeys
        ]
        ++
        [ ((m .|. shiftMask, key),     windows (shift ws))
        | (ws, key) <- extraWsKeys
        , ws /= "c"
        ]
        ++
        [ ((m, k0),                    windows (greedyView "0"))
        , ((m .|. shiftMask, k0),      windows (shift "0"))

        , ((m, kS),                    toggleSticky)

        , ((m, kF),                    withFocused $ \w -> do
                ws <- gets windowset
                if Map.member w (floating ws)
                    then windows (sink w)
                    else windows (float w (RationalRect 0 0 1 1)))

        , ((m, kD),                    toggleScratchpad "dropdown"
                                           (terminal conf))
        ]
```

A few notes on the keymap:

- `extraWs` lists every letter-named workspace. The order is
  irrelevant for behaviour but the strings here must match the strings
  in `extraWsKeys` exactly.
- `Opt+Shift+c` is intentionally **excluded** from "shift window to
  workspace c" — the default keymap binds it to "kill focused
  window", and we want to keep that.
- `Map.fromList extras `Map.union` defaultKeys conf` puts `extras`
  first: in `Data.Map`, the **left** map wins on conflict, so the
  user bindings override defaults rather than the other way around.

---

## Step 2 — locate your bundle and architecture

```bash
# Find the bundle (one of these will exist)
ls -d ~/Applications/MCMonad.app /Applications/MCMonad.app 2>/dev/null

# Find your architecture
uname -m    # arm64 → aarch64 below; x86_64 → x86_64 below
```

Set a shell variable for the bundle path so the rest of the commands
copy-paste cleanly:

```bash
APP="$HOME/Applications/MCMonad.app"   # or /Applications/MCMonad.app
```

---

## Step 3 — compile with the bundled GHC

The bundled GHC wrapper is at `$APP/Contents/MacOS/mcmonad-ghc`. It
already knows where the `mcmonad` library lives, so you do **not**
need any `-package` flags.

Apple Silicon:

```bash
"$APP/Contents/MacOS/mcmonad-ghc" --make \
    ~/.config/mcmonad/mcmonad.hs \
    -o ~/.config/mcmonad/mcmonad-aarch64-darwin \
    -v0
```

Intel:

```bash
"$APP/Contents/MacOS/mcmonad-ghc" --make \
    ~/.config/mcmonad/mcmonad.hs \
    -o ~/.config/mcmonad/mcmonad-x86_64-darwin \
    -v0
```

If this prints type errors, fix the config and rerun — nothing was
installed yet, the running McMonad is unaffected.

---

## Step 4 — write the protocol stamp

The launcher refuses to run the custom binary unless a `.proto`
sidecar matches the bundle's `Contents/Resources/protocol-version`.
Copy it across:

```bash
cp "$APP/Contents/Resources/protocol-version" \
   ~/.config/mcmonad/mcmonad-$(uname -m | sed s/arm64/aarch64/)-darwin.proto
```

(That `sed` rewrites `arm64` → `aarch64` to match the binary name on
Apple Silicon. On Intel it's a no-op.)

Verify the two files agree:

```bash
diff "$APP/Contents/Resources/protocol-version" \
     ~/.config/mcmonad/mcmonad-*-darwin.proto
```

No output = match.

---

## Step 5 — reload the launchd agent

The bundle registers itself as `com.mcmonad.agent`. Kick it so the
launcher picks up the new binary:

```bash
launchctl kickstart -k "gui/$(id -u)/com.mcmonad.agent"
```

Check the launcher log to confirm it chose the custom binary:

```bash
tail -n 20 ~/Library/Logs/mcmonad-launcher.log
```

You should see a line like:

```
[mcmonad-launcher] HH:MM:SS Using custom binary (proto v1): /Users/<you>/.config/mcmonad/mcmonad-aarch64-darwin
```

If instead you see `Custom binary proto vN != bundled vM; using
bundled` or `Custom binary lacks protocol stamp; using bundled`, go
back to step 4.

---

## Step 6 — verify

The new workspaces should respond immediately:

| Try this | Expected |
|----------|----------|
| `Opt-a` | Switch to workspace `a` (empty until you put windows there) |
| `Opt-Shift-a` on a focused window | Send the window to workspace `a` |
| `Opt-s` on a window | Toggle "sticky" (window follows you across workspaces) |
| `Opt-f` on a window | Toggle full-screen float / sink back to tile |
| `Opt-d` | Toggle Ghostty dropdown scratchpad |
| `Opt-1` … `Opt-9`, `Opt-0` | Numeric workspaces still work |

If a key does nothing, check `~/Library/Logs/mcmonad.log` for a
Haskell traceback.

---

## When the bundle is upgraded

A new `MCMonad.app` may bump the IPC protocol version. On the first
launch after upgrade the launcher will compare your `.proto` stamp
against the new `Contents/Resources/protocol-version`, see a
mismatch, and silently fall back to the bundled binary (you'll lose
your extra workspaces until you recompile).

Fix is the same three commands:

```bash
APP="$HOME/Applications/MCMonad.app"  # adjust path if needed
"$APP/Contents/MacOS/mcmonad-ghc" --make \
    ~/.config/mcmonad/mcmonad.hs \
    -o ~/.config/mcmonad/mcmonad-$(uname -m | sed s/arm64/aarch64/)-darwin \
    -v0
cp "$APP/Contents/Resources/protocol-version" \
   ~/.config/mcmonad/mcmonad-$(uname -m | sed s/arm64/aarch64/)-darwin.proto
launchctl kickstart -k "gui/$(id -u)/com.mcmonad.agent"
```

---

## Things to not do

- **Do not bind `Mod-q` to `restart`.** On macOS Tahoe, in-process
  `ghc --make` produces a fresh `cdhash`, and macOS revokes the
  Accessibility grant ~125 ms after exec (`Launch Constraint
  Violation`). The window manager spins instead of reloading.
  Recompile out-of-band as shown above.
- **Do not compile with a system or Homebrew GHC.** Only the bundled
  `mcmonad-ghc` has the `mcmonad` library in its package DB. Any
  other GHC will fail with `Could not find module 'MCMonad'`.
- **Do not skip the `.proto` stamp.** The launcher will fall back to
  the bundled binary and your config will appear to do nothing. The
  fall-back is silent in the UI; only the launcher log tells you.
- **Do not edit the binary path.** It must be exactly
  `~/.config/mcmonad/mcmonad-<arch>-darwin`. The launcher does not
  search anywhere else.

---

## Troubleshooting cheat sheet

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Opt-a` does nothing, defaults still work | Launcher silently using bundled binary | Check `~/Library/Logs/mcmonad-launcher.log`; usually a `.proto` mismatch |
| `Could not find module 'MCMonad'` at compile | Compiling with the wrong GHC | Use `$APP/Contents/MacOS/mcmonad-ghc`, not `ghc` from PATH |
| Compile succeeds, `launchctl kickstart` no effect | Stale launcher process | `launchctl bootout gui/$(id -u)/com.mcmonad.agent` then relaunch `MCMonad.app` from Finder |
| Workspaces work but focus is flaky after switching | Accessibility permission not re-granted for the custom binary | System Settings → Privacy & Security → Accessibility — toggle `MCMonad.app` off and on |
| `damaged or incomplete` when opening the app | macOS quarantine on unsigned `.app` | `xattr -cr ~/Applications/MCMonad.app` |
