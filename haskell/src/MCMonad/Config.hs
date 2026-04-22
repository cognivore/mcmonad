{-# LANGUAGE RankNTypes #-}

module MCMonad.Config
    ( MConfig(..)
    , KeyCode, Modifiers
    , optionMask, commandMask, shiftMask, controlMask
    , defaultConfig
    ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word32)

import MCMonad.Core
import MCMonad.Layout (Tall(..), Full(..), (|||))
import MCMonad.ManageHook (ManageHook, defaultManageHook)

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
    , mcKeys             = const Map.empty
    , borderWidth        = 2
    , normalBorderColor  = "#444444"
    , focusedBorderColor = "#ffffff"
    , focusFollowsMouse  = True
    , logHook            = return ()
    , startupHook        = return ()
    }
