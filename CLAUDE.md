# mcmonad

A mac-native tiling window manager. Two processes:

- **mcmonad-core** (Swift 6): A thin, bulletproof daemon that owns all macOS API
  interaction. Enumerates windows, moves/resizes them, observes events, registers
  hotkeys, focuses windows. Contains zero window management logic. It is a
  servant — it does what it's told and reports what it sees.

- **mcmonad** (Haskell): The brain. Owns the StackSet, layouts, manage hooks,
  configuration-as-code, and the event loop. This IS xmonad, but instead of
  talking to X11, it talks to mcmonad-core over a Unix socket. Users write
  Haskell to configure it, just like xmonad. QuickCheck tests verify the model.
  `catchX` isolates exceptions. `Mod-q` recompiles and restarts.

The IPC boundary between them is the clean split between pure core and IO shell
— the same architectural principle that makes xmonad reliable, but enforced by
process isolation.

---

## Why two processes

xmonad's reliability comes from separating pure logic from IO. In xmonad, that
boundary is the X monad. Here, we make it a process boundary:

- **If Haskell crashes**, Swift keeps running. launchd restarts the Haskell
  process. Swift reconnects. Windows stay where they are.
- **If Swift crashes**, launchd restarts it. Haskell reconnects and sends the
  current layout. Sub-second recovery.
- **No FFI.** Haskell never calls macOS APIs. Swift never runs layout algorithms.
  Each process does exactly one thing.
- **Real QuickCheck.** The StackSet is Haskell, tested with actual QuickCheck,
  not a port or approximation.
- **Real xmonad config.** Users write Haskell. It compiles. It runs. Just like
  xmonad.

---

## Principles of native macOS window management

*Distilled from OmniWM's implementation — the APIs and techniques that work.
This knowledge lives in mcmonad-core (Swift).*

### The three API layers

**Layer 1: SkyLight (private framework)**
`/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight` via `dlopen`/`dlsym`.
The fast path — low-latency window enumeration, bulk moves, event observation.

- `SLSMainConnectionID()` — window server connection
- `SLSWindowQueryWindows` + iterator API — bulk window enumeration with
  `GetWindowID`, `GetPID`, `GetBounds`, `GetLevel`, `GetTags`, `GetAttributes`,
  `GetParentID`
- Transactional moves: `SLSTransactionCreate` → `SLSTransactionMoveWindowWithGroup`
  → `SLSTransactionCommit` — atomic batch repositioning
- `SLSDisableUpdate`/`SLSReenableUpdate` — suppress redraws during batch ops
- Border windows: `SLSNewWindow` (type=2) + `SLWindowContextCreate` +
  `SLSSetWindowShape`

**Layer 2: Accessibility (AXUIElement)**
Required for metadata, size constraints, and resize operations.

- `AXUIElementCreateApplication(pid)` → per-app element
- Read/write `kAXPositionAttribute`, `kAXSizeAttribute`
- Read `kAXRoleAttribute`, `kAXSubroleAttribute`, `kAXTitleAttribute`, button
  attributes, `AXMinSize`, `AXMaxSize`, `AXFullScreen`
- `_AXUIElementGetWindow(element, &windowId)` — **critical private bridge**
  from AX → CGWindowID
- `AXObserverCreate`/`AXObserverAddNotification` — per-app observers

**Layer 3: Private process APIs (focus)**
- `getProcessForPID(pid, &psn)` + `_SLPSSetFrontProcessWithOptions(&psn, windowId, kCPSUserGenerated)`
- `SLPSPostEventRecordTo(&psn, eventBytes)` — 248-byte synthetic key event

### Event system

SkyLight callbacks via `SLSRegisterConnectionNotifyProc`:

| Event | ID | Payload |
|-------|----|---------|
| Window created | 1325 | spaceId (UInt64 @ 0), windowId (UInt32 @ 8) |
| Window destroyed | 1326 | spaceId (UInt64 @ 0), windowId (UInt32 @ 8) |
| Window moved | 806 | windowId (UInt32 @ 0) |
| Window resized | 807 | windowId (UInt32 @ 0) |
| Title changed | 1322 | windowId (UInt32 @ 0) |
| Window closed | 804 | windowId (UInt32 @ 0) — per-window subscription |
| Front app changed | 1508 | pid (Int32 @ 0) |

Callbacks arrive on arbitrary threads → coalesce → drain on main runloop via
`CFRunLoopPerformBlock`. Frame change events must be coalesced per-window.

### Window filtering

OmniWM's proven filter for deciding which windows to report:

1. `parentId == 0` (top-level only)
2. `level` in `{0, 3, 8}` (Normal, Floating, ModalPanel)
3. Visible attribute bit `0x2` OR tag bit 54
4. Document tag `0x1` OR (floating AND modal)
5. AX classification: close/fullscreen/zoom buttons, subrole, size constraints

### macOS constraints

- **Cannot remove titlebars.** macOS doesn't expose this.
- **Cannot move fullscreen windows.** Must exit native fullscreen first.
- **Some apps resist resizing.** Detect via `AXMinSize == AXMaxSize`.
- **Write order matters.** Shrinking: size then position. Growing: position then
  size.
- **Per-app AX threads.** One thread per app prevents a hung app from blocking
  the layout cycle.
- **Requires "Displays have separate Spaces" OFF** for multi-monitor.
- **Accessibility permission required.** Prompt via `AXIsProcessTrustedWithOptions`.

### Hotkey registration

Carbon `RegisterEventHotKey` with `GetApplicationEventTarget()`. Dispatch via
`EventHotKeyID.id`. Hotkey presses are forwarded to Haskell over IPC.

---

## Principles of xmonad's correctness

*Why xmonad never crashes. This knowledge lives in mcmonad (Haskell).*

### Pure functional core, IO shell

The StackSet is a purely functional value. Every operation on it is a pure
function `StackSet → StackSet`. IO happens at the boundary — in xmonad, that's
X11 calls. In mcmonad, it's IPC messages to the Swift daemon.

### The StackSet: correctness by construction

```
StackSet
├── current: Screen          ← focused workspace (always exactly one)
│   ├── workspace: Workspace { tag, layout, stack :: Maybe (Stack Window) }
│   ├── screen: ScreenId
│   └── screenDetail: ScreenDetail (rectangle)
├── visible: [Screen]        ← other monitors (Xinerama)
├── hidden: [Workspace]      ← not displayed
└── floating: Map Window RationalRect
```

The `Stack` is a zipper: `{ focus :: !a, up :: [a], down :: [a] }`. Focus is
tracked by construction. `up` is reversed for O(1) focus operations.

Every window appears exactly once. Enforced by API, verified by QuickCheck.

### Property-based testing

163+ QuickCheck properties: structural invariants, reversibility, idempotence,
locality, completeness. Run on random StackSets with arbitrary window/workspace/
screen counts.

### Exception isolation

```haskell
catchX :: X a -> X a -> X a
userCodeDef :: a -> X a -> X a
```

All user code (layouts, hooks) wrapped in exception handlers. A buggy layout
cannot crash the WM.

### Transparent restart

`Mod-q`: serialize state → recompile xmonad.hs → exec new binary → read state
→ resume. Zero interruption.

### The `windows` function

All state changes flow through one function:

```haskell
windows :: (WindowSet -> WindowSet) -> X ()
```

(1) Apply pure transformation, (2) run layouts, (3) send frame commands to
mcmonad-core, (4) send focus command, (5) run log hook. No other mutation path.

### Configuration as code

Users write Haskell. It compiles. The type system catches errors. The full
Haskell ecosystem is available. This is non-negotiable — it's what makes
xmonad xmonad.

---

## Architecture: compliance rules

1. **mcmonad-core contains zero window management logic.** It enumerates, moves,
   resizes, focuses, and reports. It does not decide which window goes where.
   It is a dumb pipe to macOS APIs.

2. **mcmonad contains zero macOS API calls.** All platform interaction goes
   through IPC. The Haskell process is portable in principle.

3. **xmonad is a library dependency.** `import qualified XMonad.StackSet as W`.
   We use the real, battle-tested StackSet directly — not a port, not a vendor,
   a `build-depends: xmonad`. StackSet has zero X11 imports; it is fully generic
   over window type, layout type, workspace ID, screen ID, and screen detail.
   We instantiate it with our macOS types.

4. **Exception isolation at every boundary.** `catchM` in Haskell. `do/catch`
   in Swift. A failing AX call, a buggy layout, a broken manage hook — none
   crash either process.

5. **IPC is the single point of coupling.** JSON-newline over Unix socket.
   Either process can crash and restart independently.

6. **Configuration is compiled Haskell.** Users write `~/.config/mcmonad/mcmonad.hs`.
   `Mod-q` recompiles and restarts the Haskell process. Swift stays running.

7. **Nix for tooling.** Flake provides GHC + Swift toolchains, builds both
   binaries, home-manager module runs Swift daemon via launchd.

8. **Layouts can be ported from xmonad-contrib.** Since our `LayoutClass` mirrors
   xmonad's (same methods, different monad), layouts that use only `pureLayout`
   and `pureMessage` (most of them) can be copied with trivial changes.

## Permissions

- Accessibility: required by mcmonad-core. Prompt via `AXIsProcessTrustedWithOptions`.
- No other explicit permissions needed.
