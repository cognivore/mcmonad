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
import MCMonad.Layout (Tall(..), Full(..), (|||))
import MCMonad.ManageHook (ManageHook, defaultManageHook)
import MCMonad.Operations (windows, sendMessage, kill, spawn, withFocused, screenWorkspace)

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
-- Terminal: ghostty. Mod key: option. Workspaces: 1 through 9.
-- Default manage hook floats dialogs and fixed-size windows.
-- No keybindings (users add their own via 'mcKeys').
defaultConfig :: MConfig Layout
defaultConfig = MConfig
    { terminal           = "/Applications/Ghostty.app/Contents/MacOS/ghostty"
    , layoutHook         = Layout (Tall 1 0.03 0.5 ||| Full)
    , manageHook         = defaultManageHook
    , mcWorkspaces       = map show [1 :: Int .. 9]
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
  where
    m = modMask conf
    (.|.) = (Data.Bits..|.)
