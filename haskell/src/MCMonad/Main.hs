module MCMonad.Main
    ( mcmonad
    , launch
    ) where

import Control.Monad (forever)
import Data.List (find)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word32)
import qualified XMonad.StackSet as W

import MCMonad.Config
import MCMonad.Core
import MCMonad.IPC
import MCMonad.Operations

-- | Main entry point. Connect to the Swift daemon, initialise state, and
-- run the event loop. This is what users call from their @mcmonad.hs@:
--
-- @
-- main = mcmonad def { terminal = "ghostty", ... }
-- @
mcmonad :: MConfig Layout -> IO ()
mcmonad = launch

-- | Connect to mcmonad-core, build initial state, and enter the event loop.
launch :: MConfig Layout -> IO ()
launch cfg = do
    -- 1. Connect to mcmonad-core
    conn <- connectToCore

    -- 2. Wait for Ready event
    waitForReady conn

    -- 3. Query screen geometry
    sendCommand conn QueryScreens
    screens <- waitForScreens conn

    -- 4. Build the initial StackSet
    let ws0 = buildInitialWindowSet cfg screens

    -- 5. Build the hotkey map and register hotkeys
    let keyMap    = mcKeys cfg cfg
        keyList   = Map.toAscList keyMap
        hotkeySpecs = zipWith (\i ((mods, kc), _) -> HotkeySpec i kc mods)
                              [0 ..] keyList
        -- Map from hotkey ID to action, for dispatch in the event loop
        hotkeyIdMap = Map.fromList
                      $ zipWith (\i (_, action) -> (i, action)) [0 ..] keyList
    sendCommand conn (RegisterHotkeys hotkeySpecs)

    -- 6. Query existing windows
    sendCommand conn QueryWindows
    existingWindows <- waitForWindows conn

    -- 7. Run the M monad
    let mconf = MConf { connection = conn }
        mst0  = MState { windowset = ws0, mapped = Set.empty }

    _ <- runM mconf mst0 $ do
        -- Manage all existing windows
        let hook = manageHook cfg
        mapM_ (\wi -> manage wi hook) existingWindows

        -- Run the startup hook
        userCodeDef () (startupHook cfg)

        -- Enter the event loop
        eventLoop cfg hotkeyIdMap

    return ()

-- ---------------------------------------------------------------------------
-- Initialisation helpers

-- | Block until a Ready event arrives, discarding anything else.
waitForReady :: Connection -> IO ()
waitForReady conn = do
    ev <- readEvent conn
    case ev of
        Ready -> return ()
        _     -> waitForReady conn

-- | Block until a ScreensChanged event arrives after QueryScreens.
-- Falls back to a single 1920x1080 screen if an unexpected event arrives.
waitForScreens :: Connection -> IO [ScreenInfo]
waitForScreens conn = do
    ev <- readEvent conn
    case ev of
        ScreensChanged scs -> return scs
        _ -> return [ScreenInfo 0 (Rectangle 0 0 1920 1080)]

-- | Block until a QueryWindowsResponse event arrives after QueryWindows.
-- Returns an empty list if an unexpected event arrives.
waitForWindows :: Connection -> IO [WindowInfo]
waitForWindows conn = do
    ev <- readEvent conn
    case ev of
        QueryWindowsResponse ws -> return ws
        _ -> return []

-- | Build the initial 'WindowSet' from config and screen info.
buildInitialWindowSet :: MConfig Layout -> [ScreenInfo] -> WindowSet
buildInitialWindowSet cfg screens =
    W.StackSet
        { W.current  = currentSc
        , W.visible  = visibleScs
        , W.hidden   = hiddenWSs
        , W.floating = Map.empty
        }
  where
    workspaces' = mcWorkspaces cfg
    layout'     = layoutHook cfg
    screenList  = zip [0 :: Int ..] screens

    -- Pair each screen with a workspace; remaining workspaces are hidden
    (visibleWS, hiddenWS) = splitAt (max 1 (length screenList)) workspaces'

    mkWorkspace tag = W.Workspace tag layout' Nothing

    -- Current (focused) screen -- always the first
    currentSc = case (visibleWS, screenList) of
        (tag:_, (sid, si):_) ->
            W.Screen (mkWorkspace tag) (S sid) (SD (siFrame si))
        -- Fallback: must have at least one workspace and one screen
        (tag:_, []) ->
            W.Screen (mkWorkspace tag) (S 0) (SD (Rectangle 0 0 1920 1080))
        ([], _) ->
            W.Screen (mkWorkspace "1") (S 0) (SD (Rectangle 0 0 1920 1080))

    -- Other visible screens
    visibleScs =
        [ W.Screen (mkWorkspace tag) (S sid) (SD (siFrame si))
        | (tag, (sid, si)) <- zip (drop 1 visibleWS) (drop 1 screenList)
        ]

    -- Hidden workspaces (not displayed on any screen)
    hiddenWSs = map mkWorkspace hiddenWS

-- ---------------------------------------------------------------------------
-- Event loop

-- | The main event loop: read events from the Swift daemon and dispatch.
eventLoop :: MConfig Layout -> Map.Map Int (M ()) -> M ()
eventLoop cfg hotkeyIdMap = forever $ do
    evt <- withConnection $ \conn -> io $ readEvent conn
    userCodeDef () $ handleEvent cfg hotkeyIdMap evt

-- | Dispatch a single event from the Swift daemon.
handleEvent :: MConfig Layout -> Map.Map Int (M ()) -> Event -> M ()
handleEvent cfg hotkeyIdMap evt = case evt of

    WindowCreated winfo ->
        manage winfo (manageHook cfg)

    WindowDestroyed wid -> do
        ws <- gets windowset
        let mref = findByWindowId wid (W.allWindows ws)
        whenJust mref $ \wref -> unmanage wref

    WindowFrameChanged _wid _rect ->
        -- A window was moved/resized externally (e.g. by the user dragging).
        -- For now we ignore this; a future version could update floating state.
        return ()

    FrontAppChanged _pid ->
        -- TODO: if focusFollowsMouse, update focus based on the front app
        return ()

    ScreensChanged scs ->
        rescreen scs

    HotkeyPressed hid ->
        case Map.lookup hid hotkeyIdMap of
            Just action -> action
            Nothing     -> return ()

    -- Events that arrive during init or are not actionable
    Ready                   -> return ()
    QueryWindowsResponse _  -> return ()
    QueryScreensResponse _  -> return ()

-- ---------------------------------------------------------------------------
-- Helpers

-- | Find a WindowRef by its CGWindowID in a list.
findByWindowId :: Word32 -> [WindowRef] -> Maybe WindowRef
findByWindowId wid = find (\w -> wrWindowId w == wid)
