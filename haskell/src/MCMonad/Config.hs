{-# LANGUAGE RankNTypes #-}

module MCMonad.Config
    ( MConfig(..)
    , KeyCode, Modifiers
    , optionMask, commandMask, shiftMask, controlMask
    , defaultConfig, defaultKeys
    ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Bits (Bits(..))
import Data.Word (Word32)

import qualified XMonad.StackSet as W

import qualified XMonad.Layout as XMonad (Resize(..), IncMasterN(..), ChangeLayout(..))

import MCMonad.Core
import MCMonad.Config.Keys
import MCMonad.Debug (toggleDebugOverlays)
import MCMonad.Layout (Tall(..), Full(..), (|||))
import MCMonad.ManageHook (ManageHook, defaultManageHook)
import MCMonad.Operations
    ( windows, sendMessage, kill, spawn, withFocused, screenWorkspace
    , jumpToActiveWindow, showSpotlight
    )

-- ---------------------------------------------------------------------------
-- Modifier types

-- | Modifier key bitmask (Carbon RegisterEventHotKey modifier values).
type Modifiers = Word32

-- Carbon modifier masks for RegisterEventHotKey:
-- cmdKey     = 0x0100 = 256
-- shiftKey   = 0x0200 = 512
-- optionKey  = 0x0800 = 2048
-- controlKey = 0x1000 = 4096

-- | Option/Alt key modifier.
optionMask :: Modifiers
optionMask = 0x0800

-- | Command key modifier.
commandMask :: Modifiers
commandMask = 0x0100

-- | Shift key modifier.
shiftMask :: Modifiers
shiftMask = 0x0200

-- | Control key modifier.
controlMask :: Modifiers
controlMask = 0x1000

-- ---------------------------------------------------------------------------
-- Configuration

-- | The user-facing configuration record. Parameterised over the layout type
-- so users can use concrete layouts before they get wrapped in the existential.
data MConfig l = MConfig
    { terminal           :: !String
      -- ^ Default terminal emulator command.
    , layoutHook         :: !(l WindowRef)
      -- ^ The layout algorithm applied to new workspaces.
    , manageHook         :: !ManageHook
      -- ^ Hook to classify new windows (float, shift to workspace, etc.).
    , mcWorkspaces       :: ![String]
      -- ^ Workspace names/tags.
    , modMask            :: !Modifiers
      -- ^ The modifier key used as the "mod" key in keybindings.
    , mcKeys             :: !(MConfig Layout -> Map (Modifiers, KeyCode) (M ()))
      -- ^ Keybinding generator. Given the resolved config, produce a map from
      -- (modifiers, keycode) to actions.
    , borderWidth        :: !Int
      -- ^ Width of window borders in pixels.
    , normalBorderColor  :: !String
      -- ^ Border color for unfocused windows (hex, e.g. "#444444").
    , focusedBorderColor :: !String
      -- ^ Border color for the focused window (hex, e.g. "#ffffff").
    , focusFollowsMouse  :: !Bool
      -- ^ Whether focus follows the mouse pointer.
    , mouseWarping       :: !Bool
      -- ^ Whether to warp the mouse cursor to the focused window on
      -- workspace\/screen changes. Sway disables this.
    , logHook            :: !(M ())
      -- ^ Action run after every state change (e.g. update a status bar).
    , startupHook        :: !(M ())
      -- ^ Action run once at startup.
    }

-- | Sensible default configuration.
--
-- Terminal: ghostty. Mod key: option. Workspaces: the full 62-workspace
-- "palinchron" set — 1-9, the personal layer (@0@ and the letter workspaces),
-- and 40 colour workspaces (see the 'letterWorkspaces' / 'palinchronWorkspaces'
-- section below). Default manage hook floats dialogs and fixed-size windows.
-- Default keybindings follow xmonad conventions (see 'defaultKeys').
defaultConfig :: MConfig Layout
defaultConfig = MConfig
    { terminal           = "/Applications/Ghostty.app/Contents/MacOS/ghostty"
    , layoutHook         = Layout (Tall 1 0.03 0.5 ||| Full)
    , manageHook         = defaultManageHook
    , mcWorkspaces       = map show [1 :: Int .. 9]
                        ++ ["0"]
                        ++ map fst letterWorkspaces
                        ++ palinchronWorkspaces
    , modMask            = optionMask
    , mcKeys             = defaultKeys
    , borderWidth        = 2
    , normalBorderColor  = "#444444"
    , focusedBorderColor = "#ffffff"
    , focusFollowsMouse  = True
    , mouseWarping       = True
    , logHook            = return ()
    , startupHook        = return ()
    }

-- ---------------------------------------------------------------------------
-- Palinchron-style workspaces
--
-- Beyond 1-9 the default ships the full 62-workspace "palinchron" set:
--   * the personal layer  — "0" plus the letter workspaces a z x c v b y u i o
--     n m, bound Opt+<key> to view and Opt+Shift+<key> to move; and
--   * 40 colour workspaces — 4 firmware "layers" × 10 numpad keys, painted in
--     12 LED colours (3 per layer, one per numpad column) and named
--     <colourPrefix><digit> ("r0" "g2" "o3" "b0" "f6" "m9" …).
--
-- The colour layer pairs with the Keychron Q0 + palinchron firmware (a single
-- layer key selects the layer), but every workspace is reachable on a plain
-- numpad by holding the layer's modifier combo and pressing the digit:
--
--                 View            Move
--   L1 (r/g/o)    ⌘⌥⌃⇧ (Hyper)    ⌘⌥⌃
--   L2 (b/y/w)    ⌘⌥⇧             ⌘⌥
--   L3 (f/a/c)    ⌘⌃⇧             ⌘⌃
--   L4 (p/t/m)    ⌥⌃⇧             ⌥⌃
--
-- This mirrors palinchron's Palinchron.Palette / Palinchron.Encoding so the two
-- agree on names + modifier encoding (mcmonad can't import palinchron — it
-- depends on mcmonad).

-- | The personal letter workspaces and the key that views each.
letterWorkspaces :: [(String, KeyCode)]
letterWorkspaces =
    [ ("a", kA), ("z", kZ), ("x", kX), ("c", kC), ("v", kV), ("b", kB)
    , ("y", kY), ("u", kU), ("i", kI), ("o", kO), ("n", kN), ("m", kM) ]

-- | Colour prefix for a (layer 0..3, numpad-column 0..2) cell.
palinchronColour :: Int -> Int -> Char
palinchronColour layer col = case (layer, col) of
    (0, 0) -> 'r'
    (0, 1) -> 'g'
    (0, _) -> 'o'
    (1, 0) -> 'b'
    (1, 1) -> 'y'
    (1, _) -> 'w'
    (2, 0) -> 'f'
    (2, 1) -> 'a'
    (2, _) -> 'c'
    (_, 0) -> 'p'
    (_, 1) -> 't'
    (_, _) -> 'm'

-- | Numpad column of a digit: {0,1,4,7}->0, {2,5,8}->1, {3,6,9}->2.
palinchronColumn :: Int -> Int
palinchronColumn d
    | d `elem` [2, 5, 8] = 1
    | d `elem` [3, 6, 9] = 2
    | otherwise          = 0

-- | Colour-workspace name for a (layer, digit), e.g. (0,3) -> "o3".
palinchronWorkspace :: Int -> Int -> String
palinchronWorkspace layer d = palinchronColour layer (palinchronColumn d) : show d

-- | All 40 colour workspaces, in (layer, digit) order.
palinchronWorkspaces :: [String]
palinchronWorkspaces =
    [ palinchronWorkspace layer d | layer <- [0 .. 3], d <- [0 .. 9] ]

-- | Keypad keycode for a digit 0..9.
keypadKey :: Int -> KeyCode
keypadKey d =
    [ kKeypad0, kKeypad1, kKeypad2, kKeypad3, kKeypad4
    , kKeypad5, kKeypad6, kKeypad7, kKeypad8, kKeypad9 ] !! d

-- | Modifier set for a (layer, isView). Move drops the Shift bit (per palinchron).
palinchronMods :: Int -> Bool -> Modifiers
palinchronMods layer isView =
    base .|. (if isView then shiftMask else 0)
  where
    base = case layer of
        0 -> commandMask .|. optionMask .|. controlMask
        1 -> commandMask .|. optionMask
        2 -> commandMask .|. controlMask
        _ -> optionMask  .|. controlMask

-- ---------------------------------------------------------------------------
-- Default keybindings (xmonad conventions)

-- | Default keybindings, matching xmonad conventions.
defaultKeys :: MConfig Layout -> Map (Modifiers, KeyCode) (M ())
defaultKeys conf = Map.fromList $
    -- Focus
    [ ((m, kJ),      windows W.focusDown)
    , ((m, kK),      windows W.focusUp)
    , ((m, kReturn), windows W.swapMaster)

    -- Swap
    , ((m .|. shiftMask, kJ), windows W.swapDown)
    , ((m .|. shiftMask, kK), windows W.swapUp)

    -- Layout
    , ((m, kH),      sendMessage XMonad.Shrink)
    , ((m, kL),      sendMessage XMonad.Expand)
    , ((m, kSpace),  sendMessage XMonad.NextLayout)
    , ((m, kComma),  sendMessage (XMonad.IncMasterN 1))
    , ((m, kPeriod), sendMessage (XMonad.IncMasterN (-1)))

    -- Window management
    , ((m .|. shiftMask, kC),      kill)
    , ((m, kT),                    withFocused $ \w -> windows (W.sink w))
    , ((m .|. shiftMask, kReturn), spawn (terminal conf))

    -- Debug overlays (off by default; menubar dropdown also toggles this).
    -- The overlay draws a coloured border + (workspace, wid, pid, app,
    -- title) label around every tracked window, and a red DEFIED tag
    -- when the actual frame disagrees with the most-recent SetFrames.
    , ((m .|. controlMask, kD), toggleDebugOverlays)

    -- Spotlight launcher + "follow the active window". Independent of
    -- 'modMask' (deliberately not 'm').
    --
    -- Opt+P: open the Spotlight launcher in command-runner mode — type
    -- "timer" (then minutes) or "timer 15 check on agents" to set a
    -- countdown that lives in the menu bar, or an app name ("chrome",
    -- "librewolf") to launch it. A mic button (or ⌘L) drives voice input.
    --
    -- Opt+Shift+P: open the same launcher in window-search mode ("I lost
    -- Google Chrome" → type "chr" → Enter). Tab cycles modes either way.
    --
    -- Opt+Cmd+Shift+J: jump to the workspace where the *currently active*
    -- window lives. Click a Dock icon, then press this to follow the app
    -- onto its (possibly off-screen) workspace. Keeps the Command in its
    -- triad so it can't be hit by accident.
    , ((optionMask, kP), showSpotlight "command")
    , ((optionMask .|. shiftMask, kP), showSpotlight "window")
    , ((optionMask .|. commandMask .|. shiftMask, kJ), jumpToActiveWindow)

    ]
    ++
    -- Workspaces: Mod-1..9 to view, Mod-Shift-1..9 to shift
    [ ((mask, key), windows (action ws))
    | (ws, key) <- zip (mcWorkspaces conf) [k1, k2, k3, k4, k5, k6, k7, k8, k9]
    , (action, mask) <- [(W.greedyView, m), (W.shift, m .|. shiftMask)]
    ]
    ++
    -- Screens: Mod-{w,e,r} to focus, Mod-Shift-{w,e,r} to shift
    [ ((mask, key), screenWorkspace sc >>= maybe (return ()) (windows . action))
    | (key, sc) <- zip [kW, kE, kR] [0..]
    , (action, mask) <- [(W.view, m), (W.shift, m .|. shiftMask)]
    ]
    ++
    -- Personal layer: "0" and the letter workspaces. Opt+<key> views,
    -- Opt+Shift+<key> moves the focused window — except Opt+Shift+C, which
    -- stays "kill" (above), so workspace "c" is view-only.
    [ ((mask, key), windows (act ws))
    | (ws, key)    <- ("0", k0) : letterWorkspaces
    , (act, mask)  <- (W.greedyView, m)
                    : [ (W.shift, m .|. shiftMask) | ws /= "c" ]
    ]
    ++
    -- Palinchron colour workspaces: 40 numpad-palette workspaces, each reached
    -- by its layer's modifier combo + the numpad digit (View navigates, Move
    -- sends the focused window). Ergonomic with the Keychron Q0 firmware.
    [ ((palinchronMods layer isView, keypadKey d), windows (act ws))
    | layer          <- [0 .. 3]
    , d              <- [0 .. 9]
    , let ws          = palinchronWorkspace layer d
    , (isView, act)  <- [(True, W.greedyView), (False, W.shift)]
    ]
  where
    m = modMask conf
    (.|.) = (Data.Bits..|.)
