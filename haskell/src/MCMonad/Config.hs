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
import System.Exit (exitSuccess)

import qualified XMonad.StackSet as W

import MCMonad.Core
import MCMonad.Layout (Tall(..), Full(..), (|||))
import MCMonad.ManageHook (ManageHook, defaultManageHook)
import MCMonad.Operations (windows, sendMessage, kill, spawn, withFocused)

-- ---------------------------------------------------------------------------
-- Key types

-- | A Carbon virtual key code.
type KeyCode = Word32

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
    { terminal           = "ghostty"
    , layoutHook         = Layout (Tall 1 0.03 0.5 ||| Full)
    , manageHook         = defaultManageHook
    , mcWorkspaces       = map show [1 :: Int .. 9]
    , modMask            = optionMask
    , mcKeys             = defaultKeys
    , borderWidth        = 2
    , normalBorderColor  = "#444444"
    , focusedBorderColor = "#ffffff"
    , focusFollowsMouse  = True
    , logHook            = return ()
    , startupHook        = return ()
    }

-- ---------------------------------------------------------------------------
-- Default keybindings (xmonad conventions)

-- | Carbon virtual keycodes (macOS).
kJ, kK, kH, kL, kReturn, kSpace, kC, kT, kQ, kW, kE, kR :: KeyCode
kJ = 38; kK = 40; kH = 4; kL = 37; kReturn = 36; kSpace = 49
kC = 8; kT = 17; kQ = 12; kW = 13; kE = 14; kR = 15

kComma, kPeriod :: KeyCode
kComma = 43; kPeriod = 47

k1, k2, k3, k4, k5, k6, k7, k8, k9 :: KeyCode
k1 = 18; k2 = 19; k3 = 20; k4 = 21; k5 = 23; k6 = 22; k7 = 26; k8 = 28; k9 = 25

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
    , ((m, kH),      sendMessage Shrink)
    , ((m, kL),      sendMessage Expand)
    , ((m, kSpace),  sendMessage NextLayout)
    , ((m, kComma),  sendMessage (IncMasterN 1))
    , ((m, kPeriod), sendMessage (IncMasterN (-1)))

    -- Window management
    , ((m .|. shiftMask, kC),      kill)
    , ((m, kT),                    withFocused $ \w -> windows (W.sink w))
    , ((m .|. shiftMask, kReturn), spawn (terminal conf))

    -- Quit / restart
    , ((m .|. shiftMask, kQ), io exitSuccess)
    ]
    ++
    -- Workspaces: Mod-1..9 to view, Mod-Shift-1..9 to shift
    [ ((mask, key), windows (action ws))
    | (ws, key) <- zip (mcWorkspaces conf) [k1, k2, k3, k4, k5, k6, k7, k8, k9]
    , (action, mask) <- [(W.greedyView, m), (W.shift, m .|. shiftMask)]
    ]
  where
    m = modMask conf
    (.|.) = (Data.Bits..|.)
