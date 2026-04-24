-- | Sway-compatible behaviour for mcmonad.
--
-- This module provides the 'withSway' combinator, which transforms an
-- 'MConfig' into one with Sway/i3-compatible behaviour:
--
-- * Workspaces remember which screen they belong to (affinity).
-- * Switching to a workspace on another screen moves focus there
--   instead of pulling the workspace (like Sway, unlike xmonad).
-- * The layout is an i3-style binary tree of splits (not Tall/Full).
-- * @mod-b@\/@mod-v@ set split direction, @mod-t@ toggles tabbed.
-- * @mod-r@ enters resize mode (h\/j\/k\/l resize directionally).
-- * @mod-w@ toggles sticky (window follows across workspaces).
-- * Named scratchpads for quake-style toggle windows.
--
-- Without 'withSway', mcmonad behaves exactly like xmonad.
-- With it, mcmonad behaves like Sway.
--
-- @
-- main = mcmonad (withSway defaultConfig)
-- @
module MCMonad.Sway
    ( -- * The combinator
      withSway
      -- * Affinity-aware workspace switching
    , affinityView
    , affinityShift
      -- * Per-output cycling
    , cycleOnOutput
    , cycleGlobal
      -- * Direction
    , Direction(..)
      -- * Directional focus
    , Direction2D(..)
    , focusDir
      -- * Input modes
    , enterMode
    , exitMode
    , modeAction
      -- * Sticky windows
    , toggleSticky
      -- * Named scratchpads
    , toggleScratchpad
      -- * Affinity helpers
    , getAffinity
    , setAffinity
    , clearAffinity
      -- * Pure helpers (exported for testing and advanced configs)
    , viewOnScreen
    , findVisible
    ) where

import Control.Monad (when)
import Data.Bits ((.|.))
import Data.List (findIndex, sort, sortBy)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Ord (comparing)
import qualified Data.Set as Set
import qualified XMonad.StackSet as W

import MCMonad.Core
import MCMonad.Config (MConfig(..), Modifiers, shiftMask, controlMask)
import MCMonad.Config.Keys
import MCMonad.Layout.I3Tree (I3Layout(..), I3Msg(..), SplitDir(..))
import MCMonad.IPC (sendCommand, Command(..))
import MCMonad.Operations
    ( windows, sendMessage, kill, spawn, withFocused, screenWorkspace
    , restart )

-- ---------------------------------------------------------------------------
-- The combinator

-- | Transform an mcmonad config into one with Sway-compatible behaviour.
--
-- This replaces the layout with an i3-style tree layout and the keybindings
-- with affinity-aware, Sway-style bindings. Without this combinator,
-- mcmonad behaves exactly like xmonad. With it, mcmonad behaves like Sway.
--
-- @manageHook@, @startupHook@, @logHook@, @terminal@, and all other fields
-- are passed through unchanged.
withSway :: MConfig Layout -> MConfig Layout
withSway cfg = cfg
    { layoutHook = swayLayout
    , mcKeys     = swayKeys
    }

-- | The default Sway layout: an i3-style tree with horizontal initial split.
-- Titlebar height defaults to 28px for macOS tabbed stacking.
swayLayout :: Layout WindowRef
swayLayout = Layout (I3Layout Nothing SplitH 0 28.0)

-- ---------------------------------------------------------------------------
-- Sway-style keybindings

-- | Keybinding generator for Sway mode. Uses 'affinityView' instead of
-- 'W.greedyView', adds split/tabbed/parent bindings, per-output cycling,
-- resize mode, sticky toggle, and scratchpad support.
swayKeys :: MConfig Layout -> Map (Modifiers, KeyCode) (M ())
swayKeys conf = Map.fromList $
    -- Focus / resize (mode-aware: resize mode changes h/j/k/l)
    -- Normal mode: directional spatial focus (like i3/Sway)
    -- Resize mode: directional container resize
    [ ((m, kH),                    modeAction "resize"
                                       (sendMessage (ResizeDir SplitH (-0.05)))
                                       (focusDir DirLeft))
    , ((m, kJ),                    modeAction "resize"
                                       (sendMessage (ResizeDir SplitV 0.05))
                                       (focusDir DirDown))
    , ((m, kK),                    modeAction "resize"
                                       (sendMessage (ResizeDir SplitV (-0.05)))
                                       (focusDir DirUp))
    , ((m, kL),                    modeAction "resize"
                                       (sendMessage (ResizeDir SplitH 0.05))
                                       (focusDir DirRight))
    , ((m, kReturn),               modeAction "resize"
                                       exitMode
                                       (spawn (terminal conf)))
    , ((m .|. shiftMask, kJ),      windows W.swapDown)
    , ((m .|. shiftMask, kK),      windows W.swapUp)

    -- Kill / restart
    , ((m .|. shiftMask, kQ),      kill)
    , ((m .|. shiftMask, kR),      restart)

    -- Resize mode toggle
    , ((m, kR),                    modeAction "resize" exitMode (enterMode "resize"))
    , ((m, kEscape),               exitMode)

    -- i3/Sway tree operations
    , ((m, kB), sendMessage SetSplitH)     -- next split horizontal
    , ((m, kV), sendMessage SetSplitV)     -- next split vertical
    , ((m, kT), sendMessage ToggleTabbed)  -- toggle tabbed/split
    , ((m, kA), sendMessage FocusParent)   -- focus parent container

    -- Fullscreen toggle (float at full screen or unfloat)
    , ((m, kF), withFocused $ \w -> do
            ws <- gets windowset
            if Map.member w (W.floating ws)
                then windows (W.sink w)
                else windows (W.float w (W.RationalRect 0 0 1 1)))

    -- Floating toggle
    , ((m, kSpace), withFocused $ \w -> do
            ws <- gets windowset
            if Map.member w (W.floating ws)
                then windows (W.sink w)
                else windows (W.float w (W.RationalRect 0.1 0.1 0.8 0.8)))

    -- Sticky toggle (window follows across workspace switches)
    , ((m, kW), toggleSticky)

    -- Per-output workspace cycling (Sway's prev_on_output / next_on_output)
    , ((m, kComma),                    cycleOnOutput Prev)
    , ((m, kSemicolon),                cycleOnOutput Next)
    , ((m .|. shiftMask, kComma),      cycleGlobal Prev)
    , ((m .|. shiftMask, kSemicolon),  cycleGlobal Next)
    ]
    ++
    -- Workspace switching: affinity-aware (THE difference from defaultKeys)
    [ ((m, key), affinityView ws')
    | (ws', key) <- zip (mcWorkspaces conf) [k1, k2, k3, k4, k5, k6, k7, k8, k9]
    ]
    ++
    [ ((m .|. shiftMask, key), affinityShift ws')
    | (ws', key) <- zip (mcWorkspaces conf) [k1, k2, k3, k4, k5, k6, k7, k8, k9]
    ]
  where
    m = modMask conf

-- ---------------------------------------------------------------------------
-- Input modes

-- | Enter a named input mode (e.g. \"resize\").
-- On macOS, mode keys still require the modifier (global hotkeys cannot
-- capture bare keystrokes without blocking all typing).
enterMode :: String -> M ()
enterMode mode = do
    modify $ \s -> s { inputMode = mode }
    refreshModeIndicator

-- | Return to the default input mode.
exitMode :: M ()
exitMode = do
    modify $ \s -> s { inputMode = "default" }
    refreshModeIndicator

-- | Update the workspace indicator to reflect the current input mode.
-- Shows a dagger (†) when in a non-default mode.
refreshModeIndicator :: M ()
refreshModeIndicator = do
    ws <- gets windowset
    mode <- gets inputMode
    let tag = W.tag (W.workspace (W.current ws))
        indicator = if mode /= "default"
                    then tag ++ " \x2020"
                    else tag
    withConnection $ \conn ->
        io $ sendCommand conn (SetWorkspaceIndicator indicator)

-- | Run different actions depending on the current input mode.
-- @modeAction \"resize\" resizeAction defaultAction@ runs @resizeAction@
-- when in resize mode, @defaultAction@ otherwise.
modeAction :: String -> M () -> M () -> M ()
modeAction modeName modeAct defaultAct = do
    mode <- gets inputMode
    if mode == modeName then modeAct else defaultAct

-- ---------------------------------------------------------------------------
-- Sticky windows

-- | Toggle sticky status for the focused window. Sticky windows stay
-- visible on their screen across workspace switches (Sway's @sticky toggle@).
--
-- Sticky requires floating (same as Sway/i3). If the window is tiled,
-- it is auto-floated when made sticky. Focus is preserved across
-- workspace switches for sticky windows.
toggleSticky :: M ()
toggleSticky = withFocused $ \w -> do
    s <- gets sticky
    if Set.member w s
        then modify $ \st -> st { sticky = Set.delete w (sticky st) }
        else do
            -- Sticky requires floating — auto-float if tiled
            ws <- gets windowset
            when (not $ Map.member w (W.floating ws)) $
                windows (W.float w (W.RationalRect 0.1 0.1 0.8 0.8))
            modify $ \st -> st { sticky = Set.insert w (sticky st) }

-- ---------------------------------------------------------------------------
-- Named scratchpads

-- | Toggle a named scratchpad window. If the scratchpad exists and is on
-- the current workspace, hide it. If it exists elsewhere, bring it to the
-- current workspace and float it. If it doesn't exist, spawn @cmd@ and
-- register the next window created as this scratchpad.
--
-- This gives quake-style dropdown behaviour:
--
-- @
-- toggleScratchpad \"terminal\" \"kitty\"
-- toggleScratchpad \"notes\" \"kitty -e nvim ~\/Notes\"
-- @
toggleScratchpad :: String -> String -> M ()
toggleScratchpad name cmd = do
    pads <- gets scratchpads
    case Map.lookup name pads of
        Just wr -> do
            ws <- gets windowset
            if W.member wr ws
                then do
                    -- Window exists in the StackSet
                    let ct = W.currentTag ws
                    case W.findTag wr ws of
                        Just tag | tag == ct -> do
                            -- On current workspace: hide it (move to hidden "NSP" workspace)
                            windows (W.shift "NSP" . W.focusWindow wr)
                        _ -> do
                            -- Elsewhere: bring to current workspace, float it
                            windows $ \ws' ->
                                W.float wr (W.RationalRect 0.1 0.05 0.8 0.6)
                                $ W.shiftWin (W.currentTag ws') wr ws'
                else do
                    -- Window was destroyed, clear and re-spawn
                    modify $ \s -> s { scratchpads = Map.delete name (scratchpads s) }
                    modify $ \s -> s { pendingScratchpad = Just name }
                    spawn cmd
        Nothing -> do
            -- Not registered yet, spawn and register on creation
            modify $ \s -> s { pendingScratchpad = Just name }
            spawn cmd

-- ---------------------------------------------------------------------------
-- Affinity-aware workspace switching

-- | Switch to workspace @tag@, respecting screen affinity.
--
-- Behaviour (matches Sway):
--
--   * If @tag@ is already the current workspace: no-op.
--   * If @tag@ is visible on another screen: move focus to that screen
--     (do NOT swap workspaces -- uses 'W.view', not 'W.greedyView').
--   * If @tag@ is hidden and has a recorded affinity for screen S:
--       - If S is the current screen: show @tag@ here (normal 'W.view').
--       - If S is a different visible screen: show @tag@ on S, move focus to S.
--       - If S is not present (monitor unplugged): show @tag@ on current screen.
--   * If @tag@ is hidden with no affinity: show on current screen.
affinityView :: String -> M ()
affinityView tag = do
    ws <- gets windowset
    aff <- gets affinity
    let currentSid  = W.screen (W.current ws)
        currentTag' = W.tag (W.workspace (W.current ws))
        visibleSids = map W.screen (W.visible ws)

    if tag == currentTag'
        then return ()  -- already here
        else case findVisible tag ws of
            Just _ ->
                -- Workspace is visible on another screen: focus it
                windows (W.view tag)
            Nothing ->
                -- Workspace is hidden
                case Map.lookup tag aff of
                    Just sid | sid /= currentSid
                             , sid `elem` visibleSids ->
                        -- Affinity points to a different visible screen:
                        -- show the workspace there and focus that screen
                        windows (viewOnScreen sid tag)
                    _ ->
                        -- No affinity, or affinity is current screen,
                        -- or affinity screen doesn't exist
                        windows (W.view tag)

-- | Shift the focused window to workspace @tag@, without changing focus.
-- Affinity update happens automatically via 'updateAffinities' in 'windows'.
affinityShift :: String -> M ()
affinityShift tag = windows (W.shift tag)

-- ---------------------------------------------------------------------------
-- Per-output workspace cycling

-- | Cycling direction.
data Direction = Prev | Next deriving (Eq, Show)

-- | Cycle through workspaces affiliated with the current output.
-- Matches Sway's @workspace prev_on_output@ / @workspace next_on_output@.
cycleOnOutput :: Direction -> M ()
cycleOnOutput dir = do
    ws <- gets windowset
    aff <- gets affinity
    let currentSid  = W.screen (W.current ws)
        currentTag' = W.tag (W.workspace (W.current ws))
        allTags     = sort $ map W.tag (W.workspaces ws)
        onOutput    = filter (\t -> Map.lookup t aff == Just currentSid) allTags
    case findNext dir currentTag' onOutput of
        Just target -> affinityView target
        Nothing     -> return ()

-- | Cycle through all workspaces (any output).
cycleGlobal :: Direction -> M ()
cycleGlobal dir = do
    ws <- gets windowset
    let currentTag' = W.tag (W.workspace (W.current ws))
        allTags     = sort $ map W.tag (W.workspaces ws)
    case findNext dir currentTag' allTags of
        Just target -> affinityView target
        Nothing     -> return ()

-- | Find the next (or previous) tag in a list, wrapping around.
findNext :: Direction -> String -> [String] -> Maybe String
findNext _ _ []  = Nothing
findNext _ _ [_] = Nothing  -- only one entry, nowhere to go
findNext dir current tags =
    case findIndex (== current) tags of
        Nothing -> Just (tags !! 0)  -- current not in list, go to first
        Just ix ->
            let n = length tags
                ix' = case dir of
                    Next -> (ix + 1) `mod` n
                    Prev -> (ix - 1) `mod` n
            in Just (tags !! ix')

-- ---------------------------------------------------------------------------
-- Affinity helpers

-- | Get the affinity map.
getAffinity :: M (Map String ScreenId)
getAffinity = gets affinity

-- | Set affinity for a single workspace.
setAffinity :: String -> ScreenId -> M ()
setAffinity tag sid =
    modify $ \s -> s { affinity = Map.insert tag sid (affinity s) }

-- | Clear affinity for a workspace (it will appear on whatever screen is current).
clearAffinity :: String -> M ()
clearAffinity tag =
    modify $ \s -> s { affinity = Map.delete tag (affinity s) }

-- ---------------------------------------------------------------------------
-- Directional focus (spatial navigation)

-- | Spatial direction for focus/move operations.
data Direction2D = DirLeft | DirRight | DirUp | DirDown
    deriving (Eq, Show)

-- | Move focus to the nearest window in the given direction.
-- Uses window rectangles from the last layout pass for spatial navigation.
-- This is the core of i3/Sway's h\/j\/k\/l directional focus.
focusDir :: Direction2D -> M ()
focusDir dir = do
    rects <- gets windowRects
    ws <- gets windowset
    case W.peek ws of
        Nothing -> return ()
        Just focused ->
            case Map.lookup focused rects of
                Nothing -> return ()
                Just fr ->
                    let fc = rectCenter fr
                        candidates =
                            [ (w, rectCenter r)
                            | (w, r) <- Map.toList rects
                            , w /= focused
                            , inDirection dir fc (rectCenter r)
                            ]
                        sorted = sortBy (comparing (rectDist fc . snd)) candidates
                    in case sorted of
                        ((w, _):_) -> windows (W.focusWindow w)
                        []         -> return ()

rectCenter :: Rectangle -> (Double, Double)
rectCenter (Rectangle x y w h) = (x + w / 2, y + h / 2)

inDirection :: Direction2D -> (Double, Double) -> (Double, Double) -> Bool
inDirection DirLeft  (fx, _) (cx, _) = cx < fx
inDirection DirRight (fx, _) (cx, _) = cx > fx
inDirection DirUp    (_, fy) (_, cy) = cy < fy
inDirection DirDown  (_, fy) (_, cy) = cy > fy

rectDist :: (Double, Double) -> (Double, Double) -> Double
rectDist (x1, y1) (x2, y2) = (x2 - x1) ** 2 + (y2 - y1) ** 2

-- ---------------------------------------------------------------------------
-- Pure helpers

-- | Find a workspace in the visible list by tag.
findVisible :: Eq i => i -> W.StackSet i l a sid sd -> Maybe (W.Screen i l a sid sd)
findVisible tag ws =
    case filter ((tag ==) . W.tag . W.workspace) (W.visible ws) of
        (scr:_) -> Just scr
        []      -> Nothing

-- | View a workspace on a specific screen, then focus that screen.
--
-- Two-step pure transformation: first focus the target screen (via
-- 'W.view' on its current workspace tag), then view the target workspace
-- (which replaces the now-current screen's workspace).
--
-- If the target workspace is already visible on a third screen, 'W.view'
-- moves focus there instead of pulling it -- this matches Sway's behaviour.
viewOnScreen :: (Eq sid, Eq i) => sid -> i -> W.StackSet i l a sid sd -> W.StackSet i l a sid sd
viewOnScreen sid tag ws =
    case W.lookupWorkspace sid ws of
        Nothing        -> ws  -- screen doesn't exist
        Just screenTag -> W.view tag (W.view screenTag ws)
