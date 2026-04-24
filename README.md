# McMonad

## Have You Ever Wondered What Would Happen if XMonad Wore Clown Shoes

*v0.999*

## Abstract

We bridge the gap between macOS sucking and Linux rocking by introducing McMonad — a bundle of
 - a Swift 6 daemon (`mcmonad-core`) which is a minimal bus to the macOS native window server via brittle private APIs; and
 - a Haskell process (`mcmonad`) which runs all window management logic.

They communicate over a Unix socket and the latter is configured with a regular compiled configuraion.

i3-style binary-tree-of-window-splits is enabled with the confusingly-named `withSway` combinator, which enables feature-parity with `i3` except for the fact that holding Option key is required when the WM enters "Resize mode" (denoted by the unicode dagger in the menu bar).

**macOS Tahoe+ only.**

### Getting it running

**Prerequisites:** grant Accessibility permissions (System Settings > Privacy & Security > Accessibility), and unmap Option+Space (System Settings > Keyboard > Keyboard Shortcuts > Input Sources — disable input source switching). McMonad uses Option as mod.

**Install via Nix** (recommended): `nix build github:cognivore/mcmonad`. **With home-manager** (the proper way for daily driving): add `mcmonad.url = "github:cognivore/mcmonad"` to your flake inputs, include `mcmonad.homeManagerModules.default` in your modules, then set `services.mcmonad.enable = true` and optionally `services.mcmonad.configFile` with your Haskell config. This gives you a launchd agent that manages both processes, auto-restarts on crash, and sets `MCMONAD_GHC` for recompilation.

**From the .app bundle:** grab a release from [GitHub Releases](https://github.com/cognivore/mcmonad/releases). This is very under-tested, so please fix it if it doesn't work and write _human-described_ pull requests to this repo should you undertake this undertaking.

### Switching configs

`Mod-q` recompilation is wired up but **currently requires `MCMONAD_GHC` to be set** — a GHC that has the mcmonad library in its package database. If this is noise, don't worry about it. I personally don't bind `Mod-q`, instead I manually restart once a decade when I change my config.

```bash
# 1. Get a GHC with mcmonad
GHC=$(nix build .#mcmonad-ghc --no-link --print-out-paths)/bin/ghc

# 2. Edit ~/.config/mcmonad/mcmonad.hs (or copy one from example-configs/)

# 3. Compile and restart
$GHC --make ~/.config/mcmonad/mcmonad.hs \
     -o ~/.config/mcmonad/mcmonad-aarch64-darwin -v0
kill $(pgrep -f mcmonad)
~/.config/mcmonad/mcmonad-aarch64-darwin &
```

### Troubleshooting

**"Nothing happens when I press hotkeys."** Accessibility permission was not granted, or you need to restart `MCMonadCore` and `mcmonad` after granting it. Add whichever binary is running — `MCMonadCore` + `mcmonad` if from Nix. On  `McMonad.app` if from the bundle.

**"I edited `mcmonad.hs` but nothing changed."** If `services.mcmonad.configFile` is set in home-manager, it manages `~/.config/mcmonad/mcmonad.hs` declaratively — your local edits get overwritten on `home-manager switch`. Manage it in `home-manager`!

**"Two instances are running."** `kill $(pgrep -f mcmonad)` then start one. If launchd keeps respawning: `launchctl bootout gui/$(id -u)/com.mcmonad.agent` first.

**"The app won't open — 'damaged or incomplete'."** (.app bundle only) `xattr -cr /Applications/McMonad.app` then try again. macOS quarantines unsigned apps.

**"Windows tile but focus doesn't follow."** Check `~/Library/Logs/mcmonad-core.log`. The focus ritual involves four separate private APIs; if one fails, the log says which.

---

## User guide

### Before you start

**Unmap Option+Space.** macOS binds Option+Space to input source switching by default. McMonad uses Option as the mod key (a la xmonad's mod1), so Option+Space is `NextLayout`. Go to System Settings > Keyboard > Keyboard Shortcuts > Input Sources and disable it. You will not regret this.

**Grant Accessibility permissions.** McMonad will prompt you on first launch. Without this, `mcmonad-core` cannot move or resize windows. There is no workaround.

### Default keybindings

McMonad defaults to Option as the mod key. If you are a proper Linux / XMonad user who is accustomed to the keybinds and wants the full experience on macOS, you will find [my Karabiner configuration](https://github.com/geosurge-ai/nixvana-ii/blob/main/imperative-darwin/configs/karabiner/karabiner.json) to be a nice starter pack for your keybinds. It remaps PC-style shortcuts to macOS equivalents, swaps Fn and Ctrl, adds Right Command + HJKL as arrow keys, and a few other XMonad-flavoured niceties (Option+Shift+Enter spawns a terminal, Option+P opens Spotlight, Option+Shift+C closes a window).

| Keys | Action |
|------|--------|
| `Opt-j` / `Opt-k` | Focus down / up |
| `Opt-Return` | Swap focused window with main |
| `Opt-Shift-j` / `Opt-Shift-k` | Swap down / up |
| `Opt-h` / `Opt-l` | Shrink / expand main area |
| `Opt-Space` | Next layout |
| `Opt-Shift-Return` | Spawn terminal |
| `Opt-Shift-c` | Close focused window |
| `Opt-t` | Push floating window back into tiling |
| `Opt-1`..`Opt-9` | Switch to workspace |
| `Opt-Shift-1`..`Opt-Shift-9` | Move window to workspace |
| `Opt-w` / `Opt-e` / `Opt-r` | Focus screen 1 / 2 / 3 |

### Default terminal

McMonad defaults to [Ghostty](https://ghostty.org/). If you are using Ghostty (and you should), be aware that its default UX is pretty horrible for a tiling WM setup. Specifically, Ghostty keeps running after you close the last window, which means you will have phantom Ghostty processes cluttering your workspace. The fix is one line in your Ghostty config:

```
quit-after-last-window-closed = true
```

A complete Ghostty configuration that works well with McMonad is also available [in my configuration starter pack](https://github.com/geosurge-ai/nixvana-ii/blob/main/imperative-darwin/configs/ghostty/config).

### Versioning

The versioning policy is to just keep adding 9s to the minor version after `0.` until we find a maintainer for this. Current version: `0.999`. Next: `0.9999`. Then `0.99999`. This is called "ClownVer".

---

## The big idea

<img width="1422" height="711" alt="image" src="https://github.com/user-attachments/assets/34442c06-83de-4a0d-8fe9-b347ff65d615" />

### From X to M

In 2007, Stewart and Sjanssen published *xmonad: A Tiling Window Manager* (Haskell Workshop '07), which demonstrated that a window manager could be structured as a pure function from events to window configurations, with all mutable state confined to a well-typed monad stack. The core insight was that the `X` monad — `ReaderT XConf (StateT XState IO)` — cleanly separated pure layout computation from X11herc
side effects.

We asked a simple question: what if we replace the X monad with an M monad, and replace the X11 `Display*` with a Unix socket to a macOS Accessibility server?

```haskell
-- xmonad
newtype X a = X (ReaderT XConf (StateT XState IO) a)

-- mcmonad
newtype M a = M (ReaderT MConf (StateT MState IO) a)
```

The monad stack is the same shape. `MConf` holds a socket connection where `XConf` held an X11 display. `MState` holds a `WindowSet` — the exact same `XMonad.StackSet` type, instantiated with macOS window references instead of X11 window IDs:

```haskell
-- xmonad
type WindowSet = StackSet WorkspaceId (Layout Window) Window ScreenId ScreenDetail

-- mcmonad
type WindowSet = StackSet String (Layout WindowRef) WindowRef ScreenId ScreenDetail
```

Boy, do I love strings.

Where xmonad calls `XSync`, `XSetInputFocus`, and `XMoveResizeWindow`, mcmonad sends JSON commands over a Unix socket: `SetFrames`, `FocusWindow`, `HideWindows`. Where xmonad reads X11 events, mcmonad reads events from `mcmonad-core`: `WindowCreated`, `WindowDestroyed`, `HotkeyPressed`, `ScreensChanged`.

The pure core is the single source of truth for correct window placements, we inherit the invariants and tests verbatim from XMonad.

### mcmonad-core: the Effectful backend

`mcmonad-core` is a small Swift 6 daemon that serves as the effectful backend for the M monad. It performs all I/O — talking to the window server, observing events, registering hotkeys, managing displays — and exposes a clean command/event protocol over a Unix socket at `~/.config/mcmonad/core.sock`.

The primitives it provides, and their implementation status:

**Window enumeration and observation**. We use the SkyLight private framework to enumerate windows and observe creation/destruction/move/resize events. SkyLight is Apple's private interface to the window server (`WindowServer` process) — the layer beneath AppKit that actually composites and manages windows on screen. *It is not documented, not stable across macOS versions, and not supposed to be used by third-party applications* but every macOS tiling window manager (yabai, Amethyst's lower layers, AeroSpace's experimental paths) uses it anyway.

We load it via `dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")` and resolve symbols with `dlsym` at runtime. Window filtering applies the same heuristics proven in OmniWM: top-level windows only, correct window levels (Normal, Floating, ModalPanel), proper visibility attributes and tag bits. Event coalescing deduplicates `frameChanged` per window ID and drains on the main runloop.

**Window metadata**. `AXUIElement` APIs provide structured metadata: title, app name, bundle ID, subrole, dialog classification, fixed-size detection, button presence. This feeds directly into the `WindowInfo` record that the Haskell `Query` monad reads. The `defaultManageHook` classifies windows using this metadata (dialogs and fixed-size windows float, everything else tiles).

**Frame writes**. Writing window frames uses `AXUIElement` position/size attributes. The write ordering is deliberate: when growing a window, we set position first then size (to avoid clipping at screen edges); when shrinking, size first then position (to avoid overlap). Batch writes are wrapped in `SkyLight.disableUpdate`/`reenableUpdate` to suppress redraws.

**Window focus**. Focusing a window on macOS is a three-step ritual that requires three separate private APIs:

1. `NSRunningApplication.activate` to bring the app forward,
2. `_SLPSSetFrontProcessWithOptions` via a `ProcessSerialNumber` to tell the window server which specific window to front,
3. posting synthetic key-window event records via `SLPSPostEventRecordTo` — a 248-byte event structure with magic constants at specific offsets. Finally
4. `AXUIElementPerformAction(kAXRaiseAction)` to raise via Accessibility.

This is the ugliest code in the project. It works.

**The CGWindowID-to-AXUIElement bridge**. The private function `_AXUIElementGetWindow` bridges SkyLight's `CGWindowID` namespace to the Accessibility API's `AXUIElement` namespace. Without it, we would have no way to correlate the windows we observe (via SkyLight) with the windows we manipulate (via AX). Apple provides no public API for this. Please note that other window managers report Tahoe-related bugs when window IDs are not stable between screen locks. I haven't hit this with McMonad yet, but, you know, if you suffer send PRs.

**Hotkey registration**. We use Carbon's `RegisterEventHotKey` because it is the only macOS API that provides global hotkey registration without requiring an event tap (which would need additional permissions). The API is deprecated but stable — it has worked since Mac OS X 10.0 and Apple has not removed it. If Apple removes it, I will switch to Framework Pro and SSH to my Mac Book.

**Clownordinate system**. macOS uses `CGFloat` (doubles) where X11 uses integers. AppKit has origin at bottom-left, SkyLight at top-left, and some AX calls return yet another coordinate space :clown:. `mcmonad-core` normalises everything to top-left-origin doubles before sending to Haskell.

## Closing the loop

### How we integrated mcmonad-core with xmonad

The `haskell/` directory contains ~5,500 lines of Haskell that wire xmonad's pure logic to `mcmonad-core`'s effectful backend. We shall walk through the key modules.

**`MCMonad.Core`** defines the M monad, the `WindowRef` type (a `CGWindowID` + `pid` pair), `ScreenId`, `ScreenDetail`, `Rectangle` (using doubles, not X11 integers), and the `LayoutClass` typeclass. The layout typeclass is pattern-matched to xmonad's — same methods (`runLayout`, `doLayout`, `pureLayout`, `handleMessage`, `pureMessage`, `description`), same `SomeMessage` system — but with `M` instead of `X` as the effect monad. Exception isolation follows the same pattern: `catchM` wraps `SomeException`, `userCodeDef` provides a default value on failure.

**`MCMonad.IPC`** defines the wire protocol. `Command` is an ADT of everything Haskell can ask Swift to do (`SetFrames`, `FocusWindow`, `HideWindows`, `ShowWindows`, `QueryWindows`, `QueryScreens`, `RegisterHotkeys`, `CloseWindow`, `SetWorkspaceIndicator`, `WarpMouse`). `Event` is everything Swift can report (`WindowCreated`, `WindowDestroyed`, `FrontAppChanged`, `HotkeyPressed`, `ScreensChanged`, etc.). Connection management includes exponential backoff (500ms to 30s) — if `mcmonad-core` is not running yet, the Haskell process waits.

**`MCMonad.Operations`** contains the `windows` function — the single point of truth for all state transitions, directly mirroring xmonad's architecture. When you call `windows W.focusDown`, here is what happens: (1) apply the pure `WindowSet` transformation, (2) diff old and new visible sets, (3) send `HideWindows` for windows that left, (4) send `ShowWindows` for windows that arrived, (5) run layouts for each visible screen, (6) resolve floating windows from `RationalRect` to absolute coordinates, (7) send `SetFrames` with all frame assignments, (8) send `FocusWindow` if focus changed, (9) update the workspace indicator, (10) warp the mouse if the screen or workspace changed. All window lifecycle operations — `manage`, `unmanage`, `kill` — ultimately call `windows`.

**`MCMonad.Layout`** provides `Tall`, `Full`, `Mirror`, and `Choose` (the `|||` combinator). These are pure geometric algorithms copied from xmonad: `tile`, `splitVertically`, `splitHorizontally`, `mirrorRect`. No I/O, no platform specifics. A `Tall 1 0.03 0.5` on macOS produces the exact same rectangle list as on X11 for the same input.

**`MCMonad.ManageHook`** provides the `Query` monad over `WindowInfo` metadata and the standard combinators: `—>`, `=?`, `<&&>`, `<||>`, `composeAll`, `composeOne`, `doFloat`, `doShift`, `doIgnore`. Predicates include `title`, `appName`, `bundleId`, `isDialog`, `isFixedSize`, `hasCloseButton`, `hasFullscreenButton`. The `defaultManageHook` floats dialogs, fixed-size windows, and windows without a fullscreen button.

**`MCMonad.Config`** defines the configuration record (same fields as xmonad's `XConfig`: `terminal`, `layoutHook`, `manageHook`, `modMask`, `keys`, `borderWidth`, `focusFollowsMouse`, `logHook`, `startupHook`) and the default keybindings, which follow xmonad conventions exactly.

**`MCMonad.Main`** ties it together: connect to core, wait for Ready, query screens, build initial StackSet, register hotkeys, query existing windows, batch-insert them via `manageSilent` (to avoid N layout passes during startup), run one layout pass, run the startup hook, enter the event loop. The event loop dispatches on event type and calls the appropriate M action.

### The process boundary as a reliability mechanism

If the Haskell process crashes, `mcmonad-core` keeps running. `launchd` restarts Haskell, which reconnects, queries current state, and resumes layout. If `mcmonad-core` crashes, `launchd` restarts it, and Haskell reconnects on the next event. Probably there are bugs here because `launchd` is a joke, but I suffered 0 crashes so far.

## Appendix A: Shimming for xmonad-contrib

One of our goals was to let users use their elongated 21st century screens properly.

For that, they need ThreeCol layout, which is trivially importable from xmonad-contrib. Thus we figured — heck, let's just import it! This will also allow fellow XMonad enjoyers bring their full configs to macOS without modification.

**The problem**: xmonad-contrib layouts implement `XMonad.LayoutClass`, which lives in the `X` monad and uses X11's integer `Rectangle`. McMonad has its own `LayoutClass` in the `M` monad with double-precision `Rectangle`. Thus, we are shimming it!

The shim lives in `MCMonad.Compat.XMonadContrib`:

```haskell
newtype XMonadWrapper l a = XW (l a)

fromXMonad :: (XMonad.LayoutClass l a, ...) => l a -> Layout a
fromXMonad = Layout . XW
```

`XMonadWrapper` implements McMonad's `LayoutClass` by delegating to xmonad's `LayoutClass`, converting rectangles at the boundary (`toX11Rect` truncates doubles to integers, `fromX11Rect` promotes integers to doubles). Since xmonad-contrib layouts are overwhelmingly pure — they implement `pureLayout` and `pureMessage`, not the effectful variants — the `X` monad is never actually entered. The wrapper calls `XMonad.pureLayout` directly.

This means `ThreeColMid`, and the other less useful layouts nobody I know cares about, work out of the box:

```haskell
import MCMonad.Compat.XMonadContrib (XMonadWrapper(..))
import qualified XMonad.Layout.ThreeColumns as XMonad

main = mcmonad defaultConfig
    { layoutHook = Layout (XW (XMonad.ThreeColMid 1 0.03 (1/3))
                       ||| Tall 1 0.03 0.5
                       ||| Full)
    }
```

The integer-to-double conversion introduces sub-pixel rounding. In practice this is invisible — macOS windows snap to integer coordinates anyway.

Layouts that perform effects in the `X` monad (reading X11 atoms, spawning processes, querying window properties) will not work through the shim. These are rare in xmonad-contrib, but they exist. We have not built an effectful bridge and currently have no plans to. Pure layouts cover the overwhelming majority of use cases.

---

*McMonad builds on the work of Stewart, Sjanssen, and the xmonad community. We just put clown shoes on it and made it honk on macOS.*
