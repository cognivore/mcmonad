{-# LANGUAGE OverloadedStrings #-}

-- | Debug overlay surface exposed to @mcmonad.hs@.
--
-- The debug overlay is OFF by default. Users enable it by:
--
--   * Binding 'toggleDebugOverlays' to a key in their config, or
--   * Calling 'setDebugOverlays True' in 'startupHook', or
--   * Clicking the "Debug frame overlays" item at the bottom of the
--     mcmonad-core menubar dropdown — which fires the same toggle
--     path through the IPC event 'MCMonad.IPC.MenuToggleDebug'.
--
-- When enabled, mcmonad-core draws a transparent, click-through
-- overlay on each visible workspace's screen, with a coloured border
-- around every tracked window and a label showing workspace tag,
-- windowId, pid, app, title (truncated), and — when the window
-- defies the most recent SetFrames — the intended/actual delta.
module MCMonad.Debug
    ( setDebugOverlays
    , toggleDebugOverlays
    , isDebugOverlaysOn
    ) where

import MCMonad.Core
    (M, MState(..), gets, modify, io, withConnection)
import MCMonad.IPC (Command(..), sendCommand)

-- | Set the debug overlay state. Sends a 'SetDebugOverlays' command
-- to mcmonad-core immediately; also stashes the new value in 'MState'
-- so the next 'windows' call's snapshot reflects it.
--
-- Idempotent: setting the current value is a cheap no-op except for
-- the single IPC byte.
setDebugOverlays :: Bool -> M ()
setDebugOverlays on = do
    modify $ \s -> s { debugOverlays = on }
    withConnection $ \conn -> io $ sendCommand conn (SetDebugOverlays on)

-- | Toggle the debug overlay. Reads the current flag from 'MState'
-- and inverts it. The menubar's "Debug frame overlays" item fires
-- through this same function (via 'MenuToggleDebug' → main loop).
toggleDebugOverlays :: M ()
toggleDebugOverlays = do
    cur <- gets debugOverlays
    setDebugOverlays (not cur)

-- | Read the current debug overlay flag.
isDebugOverlaysOn :: M Bool
isDebugOverlaysOn = gets debugOverlays
