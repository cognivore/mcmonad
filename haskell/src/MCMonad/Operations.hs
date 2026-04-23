module MCMonad.Operations
    ( -- * Core state transition
      windows
      -- * Window lifecycle
    , manage
    , manageSilent
    , unmanage
      -- * Layout messages
    , sendMessage
    , sendMessageWithNoRefresh
      -- * Window actions
    , kill
    , withFocused
    , reveal
    , setFocus
      -- * Launching programs
    , spawn
      -- * Restart
    , restart
    , recompile
      -- * State serialization
    , RestartState(..)
    , SerStack(..)
    , serializeState
    , getConfigDir
    , getStateFile
      -- * Screens
    , screenWorkspace
    , rescreen
      -- * Utilities
    , whenJust
    ) where

import Control.Concurrent (forkIO)
import Control.Monad (forM, void, unless, when)
import Data.List (find)
import Data.Monoid (Endo(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import System.Directory (doesFileExist, getHomeDirectory)
import System.Environment (getExecutablePath, lookupEnv)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Info (arch, os)
import System.Posix.Process (executeFile)
import System.Process (createProcess, shell, readProcessWithExitCode, CreateProcess(..))
import qualified XMonad.StackSet as W

import MCMonad.Core
import MCMonad.IPC
import MCMonad.ManageHook (ManageHook, runManageHook)

-- ---------------------------------------------------------------------------
-- The windows function
--
-- This is the single point of truth for all state transitions. Same
-- architecture as xmonad's Operations.windows:
--
--   1. Apply the pure WindowSet transformation
--   2. Hide windows that are no longer visible
--   3. Show windows that became visible
--   4. Run layouts for each visible screen
--   5. Resolve floating window positions
--   6. Send frame assignments to the Swift daemon
--   7. Send focus command
--   8. Update the mapped set

-- | Apply a pure transformation to the 'WindowSet', then synchronise
-- all visible state with the Swift daemon.
windows :: (WindowSet -> WindowSet) -> M ()
windows f = do
    old <- gets windowset
    let ws = f old

    -- Compute visibility before and after
    let oldVisible = allVisibleWindows old
        newVisible = allVisibleWindows ws

    -- 1. Update state immediately
    modify $ \s -> s { windowset = ws
                     , affinity = updateAffinities ws (affinity s) }

    conn <- asks connection

    -- 2. Hide windows no longer visible
    let toHide = filter (`notElem` newVisible) oldVisible
    io $ hPutStrLn stderr $ "WINDOWS: oldVisible=" ++ show (length oldVisible) ++ " newVisible=" ++ show (length newVisible) ++ " toHide=" ++ show (map wrWindowId toHide)
    unless (null toHide) $
        io $ sendCommand conn (HideWindows (map wrWindowId toHide))

    -- 3. Show windows that became visible
    let toShow = filter (`notElem` oldVisible) newVisible
    unless (null toShow) $
        io $ sendCommand conn (ShowWindows (map wrWindowId toShow))

    -- 4. Run layouts for each visible screen
    allRects <- fmap concat $ forM (W.current ws : W.visible ws) $ \scr -> do
        currentWS <- gets windowset
        let wsp  = W.workspace scr
            tag  = W.tag wsp
            rect = screenRect (W.screenDetail scr)
        case W.stack wsp of
            Nothing -> return []
            Just st -> do
                -- Filter out floating windows from the tiled layout
                let isTiled w = not (M.member w (W.floating currentWS))
                    tiledStack = W.filter isTiled st
                case tiledStack of
                    Nothing -> return []
                    Just t  -> do
                        (rects, ml') <- runLayout (wsp { W.stack = Just t }) rect
                        -- Update layout in the WindowSet if it changed
                        whenJust ml' $ \l' -> modify $ \s ->
                            let wset = windowset s
                                updateWsp w
                                    | W.tag w == tag = w { W.layout = l' }
                                    | otherwise      = w
                                updateScr sc = sc { W.workspace = updateWsp (W.workspace sc) }
                            in s { windowset = wset
                                { W.current = updateScr (W.current wset)
                                , W.visible = map updateScr (W.visible wset)
                                } }
                        return rects

    -- 5. Resolve floating window positions
    currentWS <- gets windowset
    let floatRects = resolveFloating currentWS

    -- 6. Send frame assignments
    let frames = map toFrameAssignment (allRects ++ floatRects)
    io $ hPutStrLn stderr $ "FRAMES: " ++ show [(wrWindowId w, rect_x r, rect_y r, rect_w r, rect_h r) | (w, r) <- allRects ++ floatRects]
    unless (null frames) $
        io $ sendCommand conn (SetFrames frames)

    -- 7. Focus the top window (only if focus actually changed)
    currentWS' <- gets windowset
    let oldFocus = W.peek old
        newFocus = W.peek currentWS'
    when (newFocus /= oldFocus) $
        case newFocus of
            Just w  -> io $ sendCommand conn (FocusWindow (wrWindowId w) (wrPid w))
            Nothing -> return ()

    -- 8. Send workspace indicator update
    let currentTag = W.tag . W.workspace . W.current $ currentWS'
    io $ sendCommand conn (SetWorkspaceIndicator currentTag)

    -- 9. Warp mouse to center of focused window when screen/workspace changed
    let oldScreen = W.screen (W.current old)
        newScreen = W.screen (W.current currentWS')
        oldTag = W.tag (W.workspace (W.current old))
        newTag = W.tag (W.workspace (W.current currentWS'))
    when (oldScreen /= newScreen || oldTag /= newTag) $ do
        case newFocus of
            Just w -> do
                let mRect = lookup w (allRects ++ floatRects)
                case mRect of
                    Just (Rectangle rx ry rw rh) ->
                        io $ sendCommand conn (WarpMouse (rx + rw / 2) (ry + rh / 2))
                    Nothing -> return ()
            Nothing -> return ()

    -- 10. Update mapped set
    modify $ \s -> s { mapped = S.fromList newVisible }

-- | All windows visible on any screen (current + visible), including
-- floating windows.
allVisibleWindows :: WindowSet -> [WindowRef]
allVisibleWindows ws =
    concatMap (W.integrate' . W.stack . W.workspace)
              (W.current ws : W.visible ws)

-- | Convert a (WindowRef, Rectangle) pair to a FrameAssignment.
toFrameAssignment :: (WindowRef, Rectangle) -> FrameAssignment
toFrameAssignment (wr, rect) = FrameAssignment (wrWindowId wr) (wrPid wr) rect

-- | Resolve floating window positions. Converts RationalRect (0..1 fractions)
-- to absolute screen coordinates based on the screen the window is on.
resolveFloating :: WindowSet -> [(WindowRef, Rectangle)]
resolveFloating ws =
    [ (w, absoluteRect)
    | (w, W.RationalRect rx ry rw rh) <- M.toList (W.floating ws)
    -- Only include floating windows that are visible on some screen
    , w `elem` allVisibleWindows ws
    , let screenR = findScreenForWindow w ws
          absoluteRect = Rectangle
              { rect_x = fromRational rx * rect_w screenR + rect_x screenR
              , rect_y = fromRational ry * rect_h screenR + rect_y screenR
              , rect_w = fromRational rw * rect_w screenR
              , rect_h = fromRational rh * rect_h screenR
              }
    ]

-- | Find the screen rectangle for a given window. Falls back to the current
-- screen if the window is not found on any screen.
findScreenForWindow :: WindowRef -> WindowSet -> Rectangle
findScreenForWindow w ws =
    case find (windowOnScreen w) (W.current ws : W.visible ws) of
        Just scr -> screenRect (W.screenDetail scr)
        Nothing  -> screenRect (W.screenDetail (W.current ws))
  where
    windowOnScreen win scr =
        win `elem` W.integrate' (W.stack (W.workspace scr))

-- ---------------------------------------------------------------------------
-- Window lifecycle

-- | Manage a new window: run the manage hook, insert it into the current
-- workspace, and apply any hook-specified transformations (float, shift, etc.).
manage :: WindowInfo -> ManageHook -> M ()
manage wi hook = do
    let wr = WindowRef (wiWindowId wi) (wiPid wi)
    -- Don't manage if already managed
    ws <- gets windowset
    when (not (W.member wr ws)) $ do
        Endo transform <- userCodeDef (Endo id) (runManageHook hook wi)
        windows (transform . W.insertUp wr)

-- | Insert a window into the StackSet without triggering layout.
-- Used during startup to batch-insert all existing windows.
manageSilent :: WindowInfo -> ManageHook -> M ()
manageSilent wi hook = do
    let wr = WindowRef (wiWindowId wi) (wiPid wi)
    ws <- gets windowset
    when (not (W.member wr ws)) $ do
        Endo transform <- userCodeDef (Endo id) (runManageHook hook wi)
        modify $ \s -> s { windowset = transform (W.insertUp wr (windowset s)) }

-- | Remove a window from management. Called when a window is destroyed.
unmanage :: WindowRef -> M ()
unmanage w = do
    ws <- gets windowset
    when (W.member w ws) $
        windows (W.delete' w)

-- ---------------------------------------------------------------------------
-- Layout messages

-- | Send a message to the layout on the current workspace. If the layout
-- handles it (returns a new layout), trigger a re-layout via 'windows'.
sendMessage :: Message a => a -> M ()
sendMessage m = do
    ws <- gets windowset
    let wsp = W.workspace (W.current ws)
        lay = W.layout wsp
    ml' <- userCodeDef Nothing $ handleMessage lay (someMessage m)
    whenJust ml' $ \l' -> do
        let wsp' = wsp { W.layout = l' }
            cur' = (W.current ws) { W.workspace = wsp' }
        modify $ \s -> s { windowset = (windowset s) { W.current = cur' } }
        windows id  -- trigger relayout

-- | Send a message to the current layout without refreshing the screen.
-- Useful for batching multiple messages before a single refresh.
sendMessageWithNoRefresh :: Message a => a -> M ()
sendMessageWithNoRefresh m = do
    ws <- gets windowset
    let wsp = W.workspace (W.current ws)
        lay = W.layout wsp
    ml' <- userCodeDef Nothing $ handleMessage lay (someMessage m)
    whenJust ml' $ \l' -> do
        let wsp' = wsp { W.layout = l' }
            cur' = (W.current ws) { W.workspace = wsp' }
        modify $ \s -> s { windowset = (windowset s) { W.current = cur' } }

-- ---------------------------------------------------------------------------
-- Window actions

-- | Close the focused window by asking the Swift daemon to close it.
kill :: M ()
kill = withFocused $ \w -> do
    conn <- asks connection
    io $ sendCommand conn (CloseWindow (wrWindowId w) (wrPid w))

-- | Perform an action on the focused window, if there is one.
withFocused :: (WindowRef -> M ()) -> M ()
withFocused f = do
    ws <- gets windowset
    whenJust (W.peek ws) f

-- | Make a window visible by sending a ShowWindows command.
reveal :: WindowRef -> M ()
reveal w = do
    conn <- asks connection
    io $ sendCommand conn (ShowWindows [wrWindowId w])

-- | Set focus to a specific window.
setFocus :: WindowRef -> M ()
setFocus w = do
    conn <- asks connection
    io $ sendCommand conn (FocusWindow (wrWindowId w) (wrPid w))

-- ---------------------------------------------------------------------------
-- Launching programs

-- | Spawn an external process. The process is fully detached from the
-- window manager.
spawn :: String -> M ()
spawn cmd = io $ void $ forkIO $ void $
    createProcess (shell cmd)
        { close_fds = True
        , create_group = True
        }

-- ---------------------------------------------------------------------------
-- Restart

-- | Serialisable snapshot of the WindowSet for transparent restart.
-- Layout state is not preserved — layouts reset to the config default.
data RestartState = RestartState
    { rsStacks     :: [(String, Maybe SerStack)]
      -- ^ (workspace tag, stack zipper)
    , rsCurrentTag :: String
      -- ^ Tag of the focused workspace
    , rsFloating   :: [(WindowRef, (Rational, Rational, Rational, Rational))]
      -- ^ Floating window positions as (x, y, w, h) rationals
    , rsAffinity   :: [(String, Int)]
      -- ^ Serialised affinity map (workspace tag, screen index)
    } deriving (Show, Read)

-- | Serialisable version of a Stack zipper.
data SerStack = SerStack
    { ssFocus :: WindowRef
    , ssUp    :: [WindowRef]
    , ssDown  :: [WindowRef]
    } deriving (Show, Read)

-- | Extract a 'RestartState' from the current 'WindowSet' and affinity map.
serializeState :: WindowSet -> M.Map String ScreenId -> RestartState
serializeState ws aff = RestartState
    { rsStacks     = map serWsp allWsps
    , rsCurrentTag = W.tag (W.workspace (W.current ws))
    , rsFloating   = [ (w, (rx, ry, rw, rh))
                     | (w, W.RationalRect rx ry rw rh) <- M.toList (W.floating ws)
                     ]
    , rsAffinity   = [(tag, n) | (tag, S n) <- M.toList aff]
    }
  where
    allWsps = map W.workspace (W.current ws : W.visible ws) ++ W.hidden ws
    serWsp wsp = (W.tag wsp, serStack <$> W.stack wsp)
    serStack (W.Stack f u d) = SerStack f u d

-- | The mcmonad config directory: @~\/.config\/mcmonad@.
getConfigDir :: IO FilePath
getConfigDir = do
    home <- getHomeDirectory
    return (home </> ".config" </> "mcmonad")

-- | Path to the user's custom config source.
getConfigSource :: IO FilePath
getConfigSource = (</> "mcmonad.hs") <$> getConfigDir

-- | Path to the compiled custom binary.
getCustomBinary :: IO FilePath
getCustomBinary = (</> ("mcmonad-" ++ arch ++ "-" ++ os)) <$> getConfigDir

-- | Path to the serialised state file for transparent restart.
getStateFile :: IO FilePath
getStateFile = (</> "mcmonad.state") <$> getConfigDir

-- | Recompile the user's @mcmonad.hs@.  Returns 'True' on success (or if
-- no custom config exists).
--
-- Requires @$MCMONAD_GHC@ to point to a GHC that has the mcmonad library
-- in its package database.  The home-manager module and app bundle both
-- set this automatically.
recompile :: IO Bool
recompile = do
    src <- getConfigSource
    exists <- doesFileExist src
    if not exists
        then return True
        else do
            mGhc <- lookupEnv "MCMONAD_GHC"
            case mGhc of
                Nothing -> do
                    hPutStrLn stderr $ unlines
                        [ "mcmonad: MCMONAD_GHC is not set."
                        , "  Set MCMONAD_GHC to a ghc that has the mcmonad library"
                        , "  in its package database. The home-manager module and"
                        , "  .app bundle set this automatically."
                        ]
                    return False
                Just ghc -> do
                    bin <- getCustomBinary
                    hPutStrLn stderr $ "mcmonad: recompiling " ++ src ++ " with " ++ ghc
                    (exit, _, err) <- readProcessWithExitCode ghc
                        ["--make", src, "-o", bin, "-v0"] ""
                    case exit of
                        ExitSuccess -> do
                            hPutStrLn stderr "mcmonad: recompile succeeded"
                            return True
                        _ -> do
                            hPutStrLn stderr $ "mcmonad: recompile FAILED:\n" ++ err
                            return False

-- | Recompile and restart the Haskell process.  The Swift daemon stays
-- running and the new process reconnects.
--
-- 1. Serialise 'WindowSet' state to disk
-- 2. Recompile @~\/.config\/mcmonad\/mcmonad.hs@ (if it exists)
-- 3. @exec@ the new binary (or self) with @--resume@
restart :: M ()
restart = do
    -- 1. Serialise state
    ws <- gets windowset
    aff <- gets affinity
    io $ do
        sf <- getStateFile
        writeFile sf (show (serializeState ws aff))
        hPutStrLn stderr $ "mcmonad: state written to " ++ sf

    -- 2. Recompile
    ok <- io recompile
    unless ok $ io $ hPutStrLn stderr "mcmonad: recompile failed, restarting with old binary"

    -- 3. Determine which binary to exec
    io $ do
        customBin <- getCustomBinary
        hasCustom <- doesFileExist customBin
        self <- getExecutablePath
        let bin = if hasCustom then customBin else self
        hPutStrLn stderr $ "mcmonad: exec " ++ bin ++ " --resume"
        executeFile bin False ["--resume"] Nothing

-- ---------------------------------------------------------------------------
-- Screens

-- | Get the workspace tag visible on a given screen.
screenWorkspace :: ScreenId -> M (Maybe String)
screenWorkspace sc = do
    ws <- gets windowset
    return $ W.lookupWorkspace sc ws

-- | Handle a change in screen configuration. Redistributes workspaces
-- across the new set of screens, preserving as much state as possible.
rescreen :: [ScreenInfo] -> M ()
rescreen newScreens = do
    ws <- gets windowset
    let -- Gather all workspaces in order: current screen, visible screens, hidden
        allWsps = W.workspace (W.current ws)
                : map W.workspace (W.visible ws)
               ++ W.hidden ws

        -- Build new screen details from ScreenInfo
        newDetails = zipWith (\i si -> (S i, SD (siFrame si)))
                             [0 :: Int ..] newScreens

        -- Assign one workspace per new screen, rest become hidden
        nScreens = length newDetails
        (screenWsps, newHidden) = splitAt nScreens allWsps

    case (screenWsps, newDetails) of
        (w:restWsps, (sid, sd):restDetails) -> do
            let newCurrent = W.Screen w sid sd
                newVisible = zipWith (\wsp (s, d) -> W.Screen wsp s d)
                                     restWsps restDetails
                ws' = ws { W.current = newCurrent
                         , W.visible = newVisible
                         , W.hidden  = newHidden
                         }
            modify $ \s -> s { windowset = ws' }
            -- Clean affinities that refer to screens no longer present
            let liveScreens = S.fromList [sid' | (sid', _) <- newDetails]
            modify $ \s -> s { affinity = M.filter (`S.member` liveScreens) (affinity s) }
            windows id  -- trigger relayout
        -- Edge cases: no workspaces or no screens should not happen in practice
        _ -> return ()

-- ---------------------------------------------------------------------------
-- Utilities

-- | Perform an action if the value is 'Just'.
whenJust :: Monad m => Maybe a -> (a -> m ()) -> m ()
whenJust Nothing  _ = return ()
whenJust (Just a) f = f a
