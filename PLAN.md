# mcmonad — Implementation Plan

## Key insight: xmonad as a library dependency

`XMonad.StackSet` has **zero X11 dependencies**. It imports only `Data.Map`,
`Data.List`, `Data.Maybe`. The type is fully generic:

```haskell
data StackSet i l a sid sd = StackSet { current, visible, hidden, floating }
```

We `cabal depend` on `xmonad` and use StackSet directly with macOS window types.
No vendoring, no forking. We inherit 17 years of battle-tested, QuickCheck-verified
zipper code. The layouts (`Tall`, `Full`, `Mirror`, `tile`) are pure math that
we copy verbatim. Only the monad, event loop, and IO boundary change.

**What we reuse from xmonad (library dependency):**
- `XMonad.StackSet` — entire module, all functions, all types
- `Stack`, `Workspace`, `Screen`, `RationalRect`
- QuickCheck property patterns (vendor the test file)
- `tile`, `splitVertically`, `splitHorizontally` algorithms

**What we redefine (same patterns, macOS types):**
- `M` monad (like `X`, but IPC connection instead of X11 Display)
- `LayoutClass` (same typeclass, `M` instead of `X` — `pureLayout`/`pureMessage` are identical)
- `ManageHook`/`Query` (same pattern, `WindowInfo` instead of X11 Window)
- `Operations.windows` (same logic, IPC commands instead of X11 calls)

## Architecture: two processes, one socket

```
┌──────────────────────────────────────────┐
│  mcmonad (Haskell)                       │
│                                          │
│  import XMonad.StackSet  ← DIRECT REUSE │
│  LayoutClass (Tall, Full — copied pure)  │
│  ManageHook (Query monad, same pattern)  │
│  M monad (ReaderT MConf (StateT MState)) │
│  windows :: (WindowSet → WindowSet) → M()│
│  Config = compiled Haskell (mcmonad.hs)  │
│                                          │
│  Event loop:                             │
│    read event from socket                │
│    update StackSet (pure)                │
│    run layouts (pure)                    │
│    send commands to socket               │
│                                          │
└──────────────┬───────────────────────────┘
               │ Unix socket
               │ ~/.config/mcmonad/core.sock
               │ JSON + newline
┌──────────────┴───────────────────────────┐
│  mcmonad-core (Swift 6)                  │
│                                          │
│  SkyLight bindings (dlopen/dlsym)        │
│  AXUIElement read/write (per-app thread) │
│  Window focus (private process APIs)     │
│  Hotkey registration (Carbon)            │
│  Display detection (NSScreen)            │
│  Event coalescing + reporting            │
│                                          │
│  NO window management logic.             │
│  Executes commands. Reports events.      │
│                                          │
└──────────────────────────────────────────┘
```

---

## IPC Protocol

Unix domain socket at `~/.config/mcmonad/core.sock`. JSON objects separated by
newline (`0x0A`). Both directions are independent streams on the same connection.

### Swift → Haskell (events)

```json
{"event":"window-created","windowId":42,"pid":1234,"title":"Untitled",
 "appName":"TextEdit","bundleId":"com.apple.TextEdit",
 "subrole":"AXStandardWindow","isDialog":false,"isFixedSize":false,
 "hasCloseButton":true,"hasFullscreenButton":true,
 "frame":{"x":100,"y":200,"w":800,"h":600}}

{"event":"window-destroyed","windowId":42}

{"event":"window-frame-changed","windowId":42,
 "frame":{"x":150,"y":200,"w":750,"h":600}}

{"event":"front-app-changed","pid":5678}

{"event":"screens-changed","screens":[
  {"screenId":0,"frame":{"x":0,"y":0,"w":2560,"h":1440}},
  {"screenId":1,"frame":{"x":2560,"y":0,"w":1920,"h":1080}}
]}

{"event":"hotkey-pressed","keyCode":38,"modifiers":2048}

{"event":"ready"}
```

### Haskell → Swift (commands)

```json
{"cmd":"set-frames","frames":[
  {"windowId":42,"frame":{"x":0,"y":25,"w":1280,"h":1415}},
  {"windowId":43,"frame":{"x":1280,"y":25,"w":1280,"h":1415}}
]}

{"cmd":"focus-window","windowId":42,"pid":1234}

{"cmd":"hide-windows","windowIds":[44,45]}

{"cmd":"show-windows","windowIds":[42,43]}

{"cmd":"query-windows"}
{"cmd":"query-screens"}

{"cmd":"register-hotkeys","hotkeys":[
  {"id":1,"keyCode":38,"modifiers":2048},
  {"id":2,"keyCode":40,"modifiers":2048}
]}

{"cmd":"close-window","windowId":42}
```

### Protocol properties

- **Stateless commands.** Each command is self-contained. Swift doesn't track
  what Haskell "expects" — it just executes.
- **Idempotent where possible.** `set-frames` sets absolute positions.
  `focus-window` focuses regardless of current state.
- **Events are fire-and-forget.** Swift doesn't wait for Haskell to acknowledge.
  Haskell processes events in order.
- **Reconnection.** If the socket disconnects, Swift waits for a new connection.
  If Haskell reconnects, it sends `query-windows` and `query-screens` to rebuild
  state, then re-applies the layout.

---

## Directory structure

```
mcmonad/
├── CLAUDE.md
├── PLAN.md
├── flake.nix                           # Both toolchains
├── flake.lock
├── .envrc                              # use flake
│
├── core/                               # mcmonad-core (Swift 6)
│   ├── Package.swift
│   └── Sources/
│       ├── MCMonadCore/
│       │   ├── Main.swift              # Entry point, socket server
│       │   ├── SkyLight/
│       │   │   ├── SkyLightBindings.swift
│       │   │   ├── SkyLightEventObserver.swift
│       │   │   └── SkyLightQuery.swift
│       │   ├── Accessibility/
│       │   │   ├── AXWindowService.swift
│       │   │   └── AXAppContext.swift
│       │   ├── Focus/
│       │   │   └── WindowFocus.swift
│       │   ├── Hotkeys/
│       │   │   └── HotkeyManager.swift
│       │   ├── Display/
│       │   │   └── DisplayManager.swift
│       │   └── IPC/
│       │       ├── SocketServer.swift
│       │       ├── Protocol.swift      # JSON codables
│       │       └── CommandExecutor.swift
│       └── mcmonad-core/
│           └── main.swift
│
├── haskell/                            # mcmonad (Haskell)
│   ├── mcmonad.cabal                   # depends on xmonad (for StackSet)
│   ├── src/
│   │   ├── MCMonad/
│   │   │   ├── Core.hs                # M monad, MState, MConf, catchM
│   │   │   ├── Layout.hs              # LayoutClass (M not X), Tall/Full/Mirror
│   │   │   ├── ManageHook.hs          # Query monad over WindowInfo
│   │   │   ├── Operations.hs          # windows, manage, unmanage
│   │   │   ├── Main.hs                # Event loop, launch, restart
│   │   │   ├── IPC.hs                 # Socket client, JSON codec
│   │   │   └── Config.hs              # MConfig, default config
│   │   └── MCMonad.hs                 # Re-exports (user-facing API)
│   ├── app/
│   │   └── Main.hs                    # Entry point
│   └── tests/
│       ├── Properties.hs              # Reuse xmonad's 163+ properties
│       └── Main.hs                    #   (StackSet is the same type!)
│
└── nix/
    ├── core-package.nix                # Swift build
    ├── haskell-package.nix             # Cabal build
    └── home-manager.nix                # launchd agents for both
```

---

## Phase 1: mcmonad-core (Swift 6 daemon)

The servant. Simple. Bulletproof. No logic.

### 1.1 SkyLight bindings

Load all symbols via `dlopen`/`dlsym` at init. Required symbols cause init
failure. Optional symbols enable graceful degradation.

```swift
final class SkyLight: @unchecked Sendable {
    static let shared: SkyLight? = SkyLight()

    private let handle: UnsafeMutableRawPointer
    let cid: Int32  // connection ID

    // Required
    let mainConnectionID: @convention(c) () -> Int32
    let queryWindows: @convention(c) (Int32, CFArray, UInt32) -> CFTypeRef?
    let queryResultCopyWindows: @convention(c) (CFTypeRef) -> CFTypeRef?
    let iteratorGetCount: @convention(c) (CFTypeRef) -> Int32
    let iteratorAdvance: @convention(c) (CFTypeRef) -> Bool
    let iteratorGetWindowID: @convention(c) (CFTypeRef) -> UInt32
    let iteratorGetPID: @convention(c) (CFTypeRef) -> Int32
    let iteratorGetBounds: @convention(c) (CFTypeRef) -> CGRect
    let iteratorGetLevel: @convention(c) (CFTypeRef) -> Int32
    let iteratorGetTags: @convention(c) (CFTypeRef) -> UInt64
    let iteratorGetAttributes: @convention(c) (CFTypeRef) -> UInt32
    let iteratorGetParentID: @convention(c) (CFTypeRef) -> UInt32

    // Transactions
    let transactionCreate: @convention(c) (Int32) -> CFTypeRef?
    let transactionCommit: @convention(c) (CFTypeRef, Int32) -> CGError
    let transactionMoveWindowWithGroup: @convention(c) (CFTypeRef, UInt32, CGPoint) -> CGError

    // Update suppression
    let disableUpdate: @convention(c) (Int32) -> Void
    let reenableUpdate: @convention(c) (Int32) -> Void

    // Notifications
    let registerConnectionNotifyProc: @convention(c) (Int32, ConnectionNotifyCallback, UInt32, UnsafeMutableRawPointer?) -> Int32
    let registerNotifyProc: @convention(c) (NotifyCallback, UInt32, UnsafeMutableRawPointer?) -> Int32
    let requestNotificationsForWindows: @convention(c) (Int32, UnsafePointer<UInt32>, Int32) -> Int32

    init?() {
        guard let h = dlopen("...SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        // Load each symbol, return nil if any required symbol missing
    }
}
```

### 1.2 Window query

```swift
struct WindowSnapshot {
    let windowId: UInt32
    let pid: pid_t
    let frame: CGRect
    let level: Int32
    let tags: UInt64
    let attributes: UInt32
    let parentId: UInt32
}

func queryAllVisibleWindows() -> [WindowSnapshot] {
    // SkyLight iterator
    // Filter: parentId == 0, level in {0, 3, 8}, visible, document or (floating+modal)
}
```

### 1.3 AX service

Per-app threads. Read metadata, write frames.

```swift
final class AXWindowService {
    struct WindowInfo: Codable {
        let windowId: UInt32
        let pid: pid_t
        let title: String?
        let appName: String?
        let bundleId: String?
        let subrole: String?
        let isDialog: Bool
        let isFixedSize: Bool
        let hasCloseButton: Bool
        let hasFullscreenButton: Bool
        let frame: CGRect
    }

    func info(windowId: UInt32, pid: pid_t) -> WindowInfo?
    func setFrame(_ frame: CGRect, windowId: UInt32, pid: pid_t, currentHint: CGRect?)
    func closeWindow(windowId: UInt32, pid: pid_t)
}
```

### 1.4 Event observer

Coalescing SkyLight callbacks → JSON events on the socket.

```swift
@MainActor
final class EventReporter {
    let socket: SocketConnection

    func start() {
        // Register SkyLight callbacks for all event types
        // On callback: decode → coalesce → drain on main runloop → JSON to socket
    }

    // Coalescing: frameChanged events are deduplicated per windowId.
    // Other events are queued in order.
}
```

### 1.5 Command executor

Reads JSON commands from socket, executes them.

```swift
@MainActor
final class CommandExecutor {
    let skylight: SkyLight
    let ax: AXWindowService

    func execute(_ command: Command) {
        switch command {
        case .setFrames(let frames):
            skylight.disableUpdate()
            // Batch AX writes with correct shrink/grow ordering
            for f in frames {
                ax.setFrame(f.frame, windowId: f.windowId, pid: f.pid, currentHint: f.currentHint)
            }
            skylight.reenableUpdate()

        case .focusWindow(let windowId, let pid):
            WindowFocus.focus(windowId: windowId, pid: pid)

        case .hideWindows(let ids):
            // SkyLight transaction to move offscreen or set level
        case .showWindows(let ids):
            // SkyLight transaction to restore

        case .queryWindows:
            let windows = queryAllVisibleWindows().compactMap { snap in
                ax.info(windowId: snap.windowId, pid: snap.pid)
            }
            socket.send(QueryWindowsResponse(windows: windows))

        case .queryScreens:
            let screens = DisplayManager.currentScreens()
            socket.send(QueryScreensResponse(screens: screens))

        case .registerHotkeys(let hotkeys):
            hotkeyManager.register(hotkeys)

        case .closeWindow(let windowId, let pid):
            ax.closeWindow(windowId: windowId, pid: pid)
        }
    }
}
```

### 1.6 Socket server

```swift
@MainActor
final class SocketServer {
    let path = "~/.config/mcmonad/core.sock"

    func start() {
        // Remove stale socket
        // Create Unix domain socket, listen
        // Accept one connection at a time (Haskell is the only client)
        // Read JSON lines → CommandExecutor
        // EventReporter writes JSON lines back
        // On disconnect: wait for reconnection
    }
}
```

### 1.7 Main

```swift
@main
struct MCMonadCore {
    static func main() {
        // 1. Check/prompt accessibility permission
        // 2. Init SkyLight (fail gracefully if unavailable)
        // 3. Start socket server
        // 4. Start event observer
        // 5. Send "ready" event when Haskell connects
        // 6. CFRunLoopRun() — never returns
    }
}
```

**Exit criterion for Phase 1:**
- `mcmonad-core` starts, creates socket, accepts connections
- Responds to `query-windows` with real window data
- Responds to `set-frames` by actually moving windows
- Reports `window-created`/`window-destroyed` events over the socket
- Tested manually: a Python/Node script connects, sends commands, receives events

---

## Phase 2: Haskell core — xmonad as library + properties

The biggest win: **don't rewrite StackSet, import it.**

### 2.1 mcmonad.cabal

```cabal
cabal-version: 3.0
name:          mcmonad
version:       0.1.0.0
build-type:    Simple

library
  exposed-modules:
    MCMonad
    MCMonad.Core
    MCMonad.Layout
    MCMonad.ManageHook
    MCMonad.Operations
    MCMonad.Main
    MCMonad.IPC
    MCMonad.Config
  build-depends:
    base          >= 4.16 && < 5,
    xmonad        >= 0.18,          -- THE KEY DEPENDENCY
    aeson         >= 2.0,
    bytestring,
    containers,
    mtl,
    network,
    text,
    QuickCheck    >= 2.14

executable mcmonad
  main-is: Main.hs
  hs-source-dirs: app
  build-depends: base, mcmonad

test-suite properties
  type: exitcode-stdio-1.0
  main-is: Main.hs
  hs-source-dirs: tests
  build-depends:
    base, mcmonad, xmonad, QuickCheck, containers
```

### 2.2 Direct StackSet reuse

```haskell
-- MCMonad/Core.hs
import qualified XMonad.StackSet as W

-- Our window type — the only thing that differs from xmonad
data WindowRef = WindowRef
    { windowCGId :: !Word32
    , windowPid  :: !Int32
    } deriving (Eq, Ord, Show, Read, Generic, FromJSON, ToJSON)

-- Our screen detail (macOS coordinates, not X11 Rectangle)
newtype ScreenDetail = SD { screenRect :: Rectangle }
    deriving (Eq, Show, Read)

-- The WindowSet is xmonad's StackSet, parameterized with our types
type WindowSet = W.StackSet
    String          -- workspace tag
    (Layout WindowRef)  -- layout
    WindowRef       -- window
    ScreenId        -- screen id
    ScreenDetail    -- screen geometry

-- ALL of these work unchanged:
-- W.view, W.greedyView, W.focusUp, W.focusDown, W.focusMaster
-- W.insertUp, W.delete, W.swapUp, W.swapDown, W.swapMaster
-- W.shift, W.shiftWin, W.float, W.sink
-- W.peek, W.member, W.findTag, W.allWindows, W.integrate
-- W.new, W.screens, W.workspaces, W.currentTag
```

### 2.3 Properties — reuse xmonad's test patterns

xmonad's Properties.hs tests StackSet with `Char` as the window type. We can
run the same properties with `WindowRef`:

```haskell
instance Arbitrary WindowRef where
    arbitrary = WindowRef <$> arbitrary <*> arbitrary

instance Arbitrary ScreenDetail where
    arbitrary = SD <$> arbitrary

-- Now run xmonad's exact property tests against our instantiation:

prop_focusUp_focusDown :: W.StackSet String Int WindowRef Int ScreenDetail -> Bool
prop_focusUp_focusDown x = W.focusUp (W.focusDown x) == x

prop_focusMaster_idem :: W.StackSet String Int WindowRef Int ScreenDetail -> Bool
prop_focusMaster_idem x = W.focusMaster (W.focusMaster x) == x

prop_insert_delete :: WindowRef -> W.StackSet String Int WindowRef Int ScreenDetail -> Bool
prop_insert_delete a x = not (W.member a x) ==> W.delete a (W.insertUp a x) == x

-- ... vendor all 163 properties from xmonad/tests/Properties.hs
-- They work UNCHANGED because StackSet is generic.
```

**Exit criterion for Phase 2:** `cabal test` passes all 163+ properties
against `StackSet String _ WindowRef _ ScreenDetail`.

---

## Phase 3: Haskell core — M monad, IPC, event loop

The glue that connects the StackSet to mcmonad-core.

### 3.1 Core.hs — The M monad

Like xmonad's X monad, but IPC replaces X11 calls:

```haskell
-- The M monad (mac monad)
newtype M a = M (ReaderT MConf (StateT MState IO) a)
    deriving (Functor, Applicative, Monad, MonadIO,
              MonadState MState, MonadReader MConf)

data MState = MState
    { windowset       :: !WindowSet
    , mapped          :: !(Set WindowId)
    , extensibleState :: !(Map String StateExtension)
    }

data MConf = MConf
    { config      :: !(MConfig Layout)
    , connection   :: !Connection          -- IPC socket handle
    , directories  :: !Directories
    }

-- Error isolation, same as xmonad
catchM :: M a -> M a -> M a
catchM job errcase = do
    st <- get
    c  <- ask
    (a, s') <- io $ runM c st job `catch` \e -> case fromException e of
        Just (_ :: ExitCode) -> throw e
        _                    -> do hPrint stderr e; runM c st errcase
    put s'
    return a

userCode :: M a -> M (Maybe a)
userCode a = catchM (Just <$> a) (return Nothing)

userCodeDef :: a -> M a -> M a
userCodeDef def a = catchM a (return def)
```

### 3.2 IPC.hs — Socket communication

```haskell
data Connection = Connection
    { connHandle :: Handle
    , connLock   :: MVar ()  -- serialize writes
    }

-- Sending commands
sendCommand :: Connection -> Command -> IO ()
sendCommand conn cmd = withMVar (connLock conn) $ \_ ->
    BSL.hPutStr (connHandle conn) (encode cmd <> "\n")

data Command
    = SetFrames [(WindowId, Rectangle)]
    | FocusWindow WindowId
    | HideWindows [WindowId]
    | ShowWindows [WindowId]
    | QueryWindows
    | QueryScreens
    | RegisterHotkeys [(Int, KeyCode, Modifiers)]
    | CloseWindow WindowId
    deriving (Generic, ToJSON)

-- Receiving events
readEvent :: Connection -> IO Event
readEvent conn = do
    line <- BS.hGetLine (connHandle conn)
    case eitherDecode line of
        Left err -> error $ "IPC decode error: " ++ err
        Right ev -> return ev

data Event
    = WindowCreated WindowInfo
    | WindowDestroyed Word32
    | WindowFrameChanged Word32 Rectangle
    | FrontAppChanged Int32
    | ScreensChanged [ScreenInfo]
    | HotkeyPressed KeyCode Modifiers
    | Ready
    deriving (Generic, FromJSON)

data WindowInfo = WindowInfo
    { wiWindowId          :: !Word32
    , wiPid               :: !Int32
    , wiTitle             :: !(Maybe Text)
    , wiAppName           :: !(Maybe Text)
    , wiBundleId          :: !(Maybe Text)
    , wiSubrole           :: !(Maybe Text)
    , wiIsDialog          :: !Bool
    , wiIsFixedSize       :: !Bool
    , wiHasCloseButton    :: !Bool
    , wiHasFullscreenButton :: !Bool
    , wiFrame             :: !Rectangle
    } deriving (Generic, FromJSON)
```

### 3.3 Operations.hs — The `windows` function

```haskell
-- The single point of truth. Same architecture as xmonad's Operations.windows.
windows :: (WindowSet -> WindowSet) -> M ()
windows f = do
    MState { windowset = old } <- get
    let ws = f old
        oldVisible = concatMap (integrate' . stack . workspace)
                     (current old : visible old)
        newVisible = concatMap (integrate' . stack . workspace)
                     (current ws : visible ws)
    modify (\s -> s { windowset = ws })

    conn <- asks connection

    -- 1. Hide windows no longer visible
    let toHide = filter (`notElem` newVisible) oldVisible
    unless (null toHide) $
        io $ sendCommand conn (HideWindows (map windowCGId toHide))

    -- 2. Run layouts for each visible screen
    allRects <- fmap concat $ forM (current ws : visible ws) $ \scr -> do
        let wsp  = workspace scr
            rect = screenRect (screenDetail scr)
        case stack wsp of
            Nothing -> return []
            Just st -> do
                let tiled = W.filter (`M.notMember` floating ws) st
                case tiled of
                    Nothing -> return []
                    Just t  -> do
                        (rects, ml') <- runLayout wsp { stack = Just t } rect
                        -- Update layout if it changed
                        whenJust ml' $ \l' ->
                            modify $ \s -> s { windowset = ... }
                        return rects

    -- 3. Apply floating window positions
    let floatRects = mapMaybe (resolveFloat ws) (M.toList (floating ws))

    -- 4. Show windows that should be visible
    let toShow = filter (`notElem` oldVisible) newVisible
    unless (null toShow) $
        io $ sendCommand conn (ShowWindows (map windowCGId toShow))

    -- 5. Send all frame positions to Swift
    io $ sendCommand conn (SetFrames (allRects ++ floatRects))

    -- 6. Set focus
    whenJust (peek ws) $ \w ->
        io $ sendCommand conn (FocusWindow w)

    -- 7. Update mapped set
    modify (\s -> s { mapped = S.fromList newVisible })

    -- 8. Log hook
    asks (logHook . config) >>= userCodeDef ()
```

### 3.4 Main.hs — Event loop

```haskell
launch :: MConfig Layout -> IO ()
launch conf = do
    -- 1. Connect to mcmonad-core socket
    conn <- connectToCore

    -- 2. Wait for Ready event
    waitForReady conn

    -- 3. Query current state
    screens <- queryScreens conn
    existingWindows <- queryWindows conn

    -- 4. Try to restore serialized state
    saved <- readStateFile
    let initWS = case saved of
            Just ws -> reconcile ws existingWindows screens
            Nothing -> buildInitialWS conf screens

    -- 5. Register hotkeys
    let keys = buildKeyMap conf
    sendCommand conn (RegisterHotkeys keys)

    -- 6. Manage existing windows
    let st = MState initWS S.empty M.empty
    runM (MConf conf conn dirs) st $ do
        forM_ existingWindows $ \wi -> manage wi
        asks (startupHook . config) >>= userCodeDef ()

        -- 7. Event loop
        forever $ do
            event <- io $ readEvent conn
            handleEvent event

handleEvent :: Event -> M ()
handleEvent ev = userCodeDef () $ case ev of
    WindowCreated wi    -> manage wi
    WindowDestroyed wid -> unmanage (WindowId wid 0)
    FrontAppChanged pid -> handleFocusFollow pid
    HotkeyPressed kc m  -> do
        keyMap <- asks (keys . config)
        whenJust (M.lookup (m, kc) keyMap) id
    ScreensChanged scs  -> rescreen scs
    _                    -> return ()

manage :: WindowInfo -> M ()
manage wi = do
    let wid = WindowId (wiWindowId wi) (wiPid wi)
    hook <- asks (manageHook . config)
    -- Run ManageHook (same as xmonad)
    g <- appEndo <$> userCodeDef (Endo id) (runQuery hook wid wi)
    windows (g . insertUp wid)

unmanage :: WindowId -> M ()
unmanage w = windows (delete w)
```

### 3.5 Layout.hs

```haskell
class (Show (layout a), Typeable layout) => LayoutClass layout a where
    runLayout :: Workspace WorkspaceId (layout a) a
              -> Rectangle
              -> M ([(a, Rectangle)], Maybe (layout a))
    runLayout (Workspace _ l ms) r = maybe (emptyLayout l r) (doLayout l r) ms

    doLayout    :: layout a -> Rectangle -> Stack a -> M ([(a, Rectangle)], Maybe (layout a))
    pureLayout  :: layout a -> Rectangle -> Stack a -> [(a, Rectangle)]
    handleMessage :: layout a -> SomeMessage -> M (Maybe (layout a))
    pureMessage :: layout a -> SomeMessage -> Maybe (layout a)
    description :: layout a -> String

-- Built-in: Tall, Mirror, Full, Choose (|||)
-- Same implementations as xmonad — they're pure, they just work.
data Tall a = Tall !Int !Rational !Rational  -- nmaster delta ratio

instance LayoutClass Tall a where
    pureLayout (Tall nmaster _ frac) r s = zip ws rs
      where
        ws = integrate s
        rs = tile frac r nmaster (length ws)

    pureMessage (Tall n d r) m
        | Just Shrink <- fromMessage m = Just $ Tall n d (max 0 $ r - d)
        | Just Expand <- fromMessage m = Just $ Tall n d (min 1 $ r + d)
        | Just (IncMasterN i) <- fromMessage m = Just $ Tall (max 0 $ n + i) d r
        | otherwise = Nothing

-- tile is the same algorithm as xmonad's
tile :: Rational -> Rectangle -> Int -> Int -> [Rectangle]
```

### 3.6 ManageHook.hs

```haskell
type ManageHook = Query (Endo WindowSet)

newtype Query a = Query (ReaderT (WindowId, WindowInfo) M a)
    deriving (Functor, Applicative, Monad)

-- Combinators (same as xmonad)
title     :: Query String
appName   :: Query String
className :: Query String  -- bundleId
(-->)     :: Query Bool -> Query (Endo WindowSet) -> Query (Endo WindowSet)
(=?)      :: Eq a => Query a -> a -> Query Bool
(<+>)     :: Monoid m => Query m -> Query m -> Query m

doFloat   :: ManageHook
doShift   :: WorkspaceId -> ManageHook
doIgnore  :: ManageHook

-- Default heuristics (from OmniWM's WindowDecisionKernel)
defaultManageHook :: ManageHook
defaultManageHook = composeAll
    [ isDialog              --> doFloat
    , isFixedSize           --> doFloat
    , noFullscreenButton    --> doFloat
    ]
```

### 3.7 Config.hs

```haskell
data MConfig l = MConfig
    { terminal           :: !String
    , layoutHook         :: !(l WindowId)
    , manageHook         :: !ManageHook
    , handleEventHook    :: !(Event -> M All)
    , workspaces         :: ![String]
    , modMask            :: !Modifiers
    , keys               :: !(MConfig Layout -> Map (Modifiers, KeyCode) (M ()))
    , borderWidth        :: !Int
    , normalBorderColor  :: !String
    , focusedBorderColor :: !String
    , focusFollowsMouse  :: !Bool
    , logHook            :: !(M ())
    , startupHook        :: !(M ())
    }

instance Default (MConfig l) where
    def = MConfig
        { terminal           = "ghostty"
        , layoutHook         = Tall 1 (3/100) (1/2) ||| Full
        , manageHook         = defaultManageHook
        , workspaces         = map show [1..9 :: Int]
        , modMask            = optionMask  -- Option key
        , keys               = defaultKeys
        , borderWidth        = 2
        , normalBorderColor  = "#444444"
        , focusedBorderColor = "#ff6600"
        , focusFollowsMouse  = False
        , logHook            = return ()
        , startupHook        = return ()
        , handleEventHook    = const (return (All True))
        }
```

### 3.8 User configuration (`~/.config/mcmonad/mcmonad.hs`)

```haskell
import MCMonad

main :: IO ()
main = mcmonad def
    { terminal           = "ghostty"
    , modMask            = optionMask
    , layoutHook         = Tall 1 (3/100) (55/100) ||| Full
    , manageHook         = composeAll
        [ appName =? "Finder" --> doFloat
        , appName =? "Slack"  --> doShift "9"
        , title   =? "Picture in Picture" --> doFloat
        ] <+> defaultManageHook
    , workspaces         = map show [1..9 :: Int]
    , borderWidth        = 2
    , focusedBorderColor = "#ff6600"
    }
```

Compilation: `mcmonad` detects `mcmonad.hs`, compiles it (GHC/Cabal/Nix),
and `exec`s the new binary — same as xmonad. `Mod-q` recompiles and restarts
the Haskell process. Swift stays running.

**Exit criterion for Phase 3:**
- `mcmonad` connects to `mcmonad-core`, queries windows, builds StackSet
- Hotkey presses trigger StackSet transformations
- `windows` sends correct frame commands to Swift
- Windows actually tile on screen
- `Mod-q` recompiles and restarts without losing window positions

---

## Phase 4: Default keybindings

```haskell
defaultKeys :: MConfig Layout -> Map (Modifiers, KeyCode) (M ())
defaultKeys conf = M.fromList $
    -- Focus
    [ ((modMask conf,               kJ), windows focusDown)
    , ((modMask conf,               kK), windows focusUp)
    , ((modMask conf,               kM), windows focusMaster)

    -- Swap
    , ((modMask conf,               kReturn), windows swapMaster)
    , ((modMask conf .|. shiftMask, kJ), windows swapDown)
    , ((modMask conf .|. shiftMask, kK), windows swapUp)

    -- Layout
    , ((modMask conf,               kH), sendMessage Shrink)
    , ((modMask conf,               kL), sendMessage Expand)
    , ((modMask conf,               kSpace), sendMessage NextLayout)
    , ((modMask conf,               kComma), sendMessage (IncMasterN 1))
    , ((modMask conf,               kPeriod), sendMessage (IncMasterN (-1)))

    -- Window management
    , ((modMask conf .|. shiftMask, kC), kill)
    , ((modMask conf,               kT), withFocused $ windows . sink)
    , ((modMask conf .|. shiftMask, kReturn), spawn $ terminal conf)

    -- Quit / restart
    , ((modMask conf .|. shiftMask, kQ), io exitSuccess)
    , ((modMask conf,               kQ), restart)
    ]
    ++
    -- Workspaces: Mod-1..9 to view, Mod-Shift-1..9 to shift
    [ ((m .|. modMask conf, k), windows $ f i)
    | (i, k) <- zip (workspaces conf) [k1..k9]
    , (f, m) <- [(view, 0), (shift, shiftMask)]
    ]
    ++
    -- Screens: Mod-{w,e,r} to focus, Mod-Shift-{w,e,r} to shift
    [ ((m .|. modMask conf, k), screenWorkspace sc >>= flip whenJust (windows . f))
    | (k, sc) <- zip [kW, kE, kR] [0..]
    , (f, m)  <- [(view, 0), (shift, shiftMask)]
    ]
```

---

## Phase 5: Nix packaging

### flake.nix

```nix
{
  description = "mcmonad — mac-native tiling window manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = nixpkgs.legacyPackages.${system};
      in {
        packages = {
          core = pkgs.callPackage ./nix/core-package.nix { };
          haskell = pkgs.callPackage ./nix/haskell-package.nix { };
          default = pkgs.symlinkJoin {
            name = "mcmonad";
            paths = [ self.packages.${system}.core self.packages.${system}.haskell ];
          };
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # Swift
            swift swiftformat
            # Haskell
            ghc cabal-install haskell-language-server
            # Shared
            jq  # for IPC debugging
          ];
        };
      }
    ) // {
      homeManagerModules.default = import ./nix/home-manager.nix self;
    };
}
```

### home-manager.nix

Two launchd agents:

```nix
# mcmonad-core: always running, KeepAlive
launchd.agents.mcmonad-core = {
  enable = true;
  config = {
    ProgramArguments = [ "${cfg.package}/bin/mcmonad-core" ];
    KeepAlive = true;
    RunAtLoad = true;
    StandardOutPath = "${config.home.homeDirectory}/Library/Logs/mcmonad-core.log";
    StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/mcmonad-core.log";
  };
};

# mcmonad: depends on core, also KeepAlive
launchd.agents.mcmonad = {
  enable = true;
  config = {
    ProgramArguments = [ "${cfg.package}/bin/mcmonad" ];
    KeepAlive = true;
    RunAtLoad = true;
    StandardOutPath = "${config.home.homeDirectory}/Library/Logs/mcmonad.log";
    StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/mcmonad.log";
  };
};
```

---

## Phase 6: Multi-monitor

Already modeled in StackSet (current + visible). Wire to real displays:

- Swift sends `screens-changed` events on `NSApplication.didChangeScreenParametersNotification`
- Haskell updates ScreenDetails in StackSet, calls `rescreen`
- `view` with Xinerama: swap workspaces between screens
- `greedyView`: pull workspace to current screen

```haskell
rescreen :: [ScreenInfo] -> M ()
rescreen newScreens = do
    -- Same logic as xmonad's rescreen
    -- Redistribute workspaces across new screen configuration
    windows id  -- trigger relayout
```

---

## Phase 7: Polish

- Border windows via SkyLight (Swift draws them, Haskell tells Swift which
  window is focused)
- Status bar: Haskell sends workspace/layout/title info via logHook (same
  pattern as xmobar/polybar integration in xmonad)
- Mouse dragging for floating windows (Swift detects drag, reports to Haskell,
  Haskell updates float position, sends new frame)
- Frame verification: Swift verifies frames after write, reports mismatches
- `AXEnhancedUserInterface` toggling for problematic apps

---

## Implementation order

| Phase | Deliverable | Language | Risk |
|-------|------------|----------|------|
| 1 | mcmonad-core daemon | Swift | Medium — private APIs |
| 2 | StackSet + 163 QuickCheck properties | Haskell | Low — pure logic, can vendor |
| 3 | M monad, IPC, event loop, `windows` | Haskell | Medium — integration |
| 4 | Default keybindings | Haskell | Low |
| 5 | Nix flake + home-manager | Nix | Low |
| 6 | Multi-monitor | Both | Medium |
| 7 | Polish | Both | Low |

Phases 1 and 2 are independent and can be built in parallel. Phase 3 wires
them together — that's where the first window actually tiles.

---

## Risk register

### SkyLight API stability
Private frameworks change between macOS versions. Load symbols with `dlsym`,
treat missing symbols as optional. Fall back to AX-only if SkyLight unavailable.
Test on each macOS release.

### IPC latency
Window management must feel instant. The socket is local (no network). JSON
encoding/decoding is fast for small messages. Batch operations (`set-frames`)
minimize round trips. If latency is perceptible, switch to a binary protocol
(MessagePack or custom).

### Process coordination
Two processes must stay in sync. Strategy:
- Swift is the source of truth for what exists on screen
- Haskell is the source of truth for where things should be
- On reconnect, Haskell queries Swift and rebuilds state
- No shared mutable state — only messages

### Haskell on macOS / Nix
GHC works on macOS. Nix can build Haskell packages. `haskell.nix` or
`nixpkgs.haskellPackages` are both options. The dependency set is small
(aeson, network, containers, mtl, QuickCheck) — no exotic packages.

### User experience: two processes
Users shouldn't need to think about two processes. The Nix home-manager module
manages both. `Mod-q` restarts only Haskell (Swift stays). From the user's
perspective, it's one window manager.
