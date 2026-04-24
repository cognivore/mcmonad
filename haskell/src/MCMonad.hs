-- | MCMonad: mac-native tiling window manager.
--
-- This module re-exports the user-facing API. Import this in your
-- @~\/.config\/mcmonad\/mcmonad.hs@ configuration file:
--
-- @
-- import MCMonad
--
-- main = mcmonad defaultConfig
--     { terminal   = "\/Applications\/Ghostty.app\/Contents\/MacOS\/ghostty"
--     , layoutHook = Layout (Tall 1 0.03 0.5 ||| Full)
--     , modMask    = optionMask
--     }
-- @
module MCMonad
    ( module MCMonad.Core
    , module MCMonad.Config
    , module MCMonad.Config.Keys
    , module MCMonad.Layout
    , module MCMonad.Layout.I3Tree
    , module MCMonad.ManageHook
    , module MCMonad.Operations
    , module MCMonad.Main
    , module MCMonad.Sway
    -- * Re-exports from XMonad.StackSet (qualified as W)
    , module W
    ) where

import MCMonad.Core
import MCMonad.Config
import MCMonad.Config.Keys
import MCMonad.Layout
import MCMonad.Layout.I3Tree
import MCMonad.ManageHook
import MCMonad.Operations
import MCMonad.Main
import MCMonad.Sway

-- Selective re-exports from StackSet to avoid conflicts with MonadState.modify
import XMonad.StackSet as W hiding (modify, modify', filter)
