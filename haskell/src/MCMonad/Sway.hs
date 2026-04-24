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
      -- * Affinity helpers
    , getAffinity
    , setAffinity
    , clearAffinity
      -- * Pure helpers (exported for testing and advanced configs)
    , viewOnScreen
    , findVisible
    ) where

import Data.Bits ((.|.))
import Data.List (findIndex, sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified XMonad.Layout as XLayout (Resize(..))
import qualified XMonad.StackSet as W

import MCMonad.Core
import MCMonad.Config (MConfig(..), Modifiers, shiftMask)
import MCMonad.Config.Keys
import MCMonad.Layout.I3Tree (I3Layout(..), I3Msg(..), SplitDir(..))
import MCMonad.Operations
    ( windows, sendMessage, kill, spawn, withFocused, screenWorkspace )

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
swayLayout :: Layout WindowRef
swayLayout = Layout (I3Layout Nothing SplitH 0)

-- ---------------------------------------------------------------------------
-- Sway-style keybindings

-- | Keybinding generator for Sway mode. Uses 'affinityView' instead of
-- 'W.greedyView', adds split/tabbed/parent bindings, and per-output cycling.
swayKeys :: MConfig Layout -> Map (Modifiers, KeyCode) (M ())
swayKeys conf = Map.fromList $
    -- Focus
    [ ((m, kJ),                    windows W.focusDown)
    , ((m, kK),                    windows W.focusUp)
    , ((m, kReturn),               windows W.swapMaster)
    , ((m .|. shiftMask, kJ),      windows W.swapDown)
    , ((m .|. shiftMask, kK),      windows W.swapUp)

    -- Window management
    , ((m .|. shiftMask, kC),      kill)
    , ((m .|. shiftMask, kReturn), spawn (terminal conf))

    -- i3/Sway tree operations
    , ((m, kB), sendMessage SetSplitH)     -- next split horizontal
    , ((m, kV), sendMessage SetSplitV)     -- next split vertical
    , ((m, kT), sendMessage ToggleTabbed)  -- toggle tabbed/split
    , ((m, kA), sendMessage FocusParent)   -- focus parent container

    -- Resize
    , ((m, kH), sendMessage XLayout.Shrink)
    , ((m, kL), sendMessage XLayout.Expand)

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
    ++
    -- Screen focus (same as xmonad -- orthogonal to affinity)
    [ ((mask, key), screenWorkspace sc >>= maybe (return ()) (windows . action))
    | (key, sc) <- zip [kW, kE, kR] [0..]
    , (action, mask) <- [(W.view, m), (W.shift, m .|. shiftMask)]
    ]
  where
    m = modMask conf

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
