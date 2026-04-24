-- | Sway/i3-style configuration for mcmonad.
--
-- Replicates the keybindings from cstnix1's sway.nix:
--   - Option (Mod4/Super) as modifier
--   - i3-style tree layout with splith/splitv/tabbed
--   - 20 workspaces (1-10 on number row, 11-20 with Ctrl)
--   - Affinity-aware workspace switching (Sway behaviour)
--   - Per-output cycling on comma/semicolon
--   - Resize mode (Mod+r toggles, Mod+h/j/k/l resize directionally)
--   - Sticky windows (Mod+w)
--   - Quake-style scratchpads (F12 dropdown terminal, Mod+* notes)
--   - Focus follows mouse disabled
--
-- Carbon keycodes are physical key positions, so this works on any
-- keyboard layout (QWERTY, AZERTY, Dvorak, etc.). On French AZERTY,
-- Mod+k1 is what you'd call "Mod+&" since '&' is on the '1' key.

import MCMonad
import MCMonad.Config.Keys
import qualified XMonad.Layout as XMonad (Resize(..))
import qualified Data.Map.Strict as Map
import Data.Bits ((.|.))

main :: IO ()
main = mcmonad $ (withSway defaultConfig
    { terminal        = "/Applications/kitty.app/Contents/MacOS/kitty"
    , modMask         = optionMask  -- Mod4/Super maps to Option on macOS
    , mcWorkspaces    = map show [1 :: Int .. 20] ++ ["NSP"]
    , focusFollowsMouse = False
    , mouseWarping    = False    -- cst disables mouse warping
    , borderWidth     = 0
    })
    { mcKeys = cstKeys }

-- | Keybindings matching cstnix1's sway config.
cstKeys :: MConfig Layout -> Map.Map (Modifiers, KeyCode) (M ())
cstKeys conf = Map.fromList $
    -- Terminal
    [ ((m, kReturn),               modeAction "resize" exitMode
                                       (spawn (terminal conf)))

    -- Kill / restart
    , ((m .|. shiftMask, kQ),      kill)
    , ((m .|. shiftMask, kR),      restart)

    -- Focus / resize (mode-aware: resize mode changes h/j/k/l)
    -- Resize works on both tiled (tree) and floating (scratchpad) windows
    , ((m, kJ),                    modeAction "resize"
                                       (resizeOrFloat SplitV 0.05)
                                       (windows focusDown))
    , ((m, kK),                    modeAction "resize"
                                       (resizeOrFloat SplitV (-0.05))
                                       (windows focusUp))
    , ((m, kH),                    modeAction "resize"
                                       (resizeOrFloat SplitH (-0.05))
                                       (sendMessage XMonad.Shrink))
    , ((m, kL),                    modeAction "resize"
                                       (resizeOrFloat SplitH 0.05)
                                       (sendMessage XMonad.Expand))

    -- Directional window movement (i3's move left/right/up/down)
    , ((m .|. shiftMask, kH),      moveDir DirLeft)
    , ((m .|. shiftMask, kJ),      moveDir DirDown)
    , ((m .|. shiftMask, kK),      moveDir DirUp)
    , ((m .|. shiftMask, kL),      moveDir DirRight)

    -- Resize mode: Mod+r toggles, Mod+Escape exits
    -- (macOS global hotkeys require modifier — bare keys would block typing)
    , ((m, kR),                    modeAction "resize" exitMode (enterMode "resize"))
    , ((m, kEscape),               exitMode)

    -- i3/Sway tree operations
    , ((m, kB),                    sendMessage SetSplitH)
    , ((m, kV),                    sendMessage SetSplitV)
    , ((m, kT),                    sendMessage ToggleTabbed)
    , ((m, kA),                    sendMessage FocusParent)

    -- Fullscreen toggle (float at full screen size or unfloat)
    , ((m, kF),                    withFocused $ \w -> do
            ws <- gets windowset
            if Map.member w (floating ws)
                then windows (sink w)
                else windows (float w (RationalRect 0 0 1 1)))

    -- Floating toggle
    , ((m, kSpace),                withFocused $ \w -> do
            ws <- gets windowset
            if Map.member w (floating ws)
                then windows (sink w)
                else windows (float w (RationalRect 0.1 0.1 0.8 0.8)))

    -- Sticky toggle (Sway's "sticky toggle")
    , ((m, kW),                    toggleSticky)

    -- Launcher (Spotlight on macOS)
    , ((m, kD),                    spawn "osascript -e 'tell application \"System Events\" to keystroke space using command down'")

    -- Quake-style scratchpads
    -- F12: dropdown terminal (like cst's kitty --class=dropdown)
    , ((0, kF12),                  toggleScratchpad "dropdown"
                                       (terminal conf))
    -- Mod+*: floating notes (like cst's vimFloat)
    -- kBackslash = 0x2A: the ISO key next to Enter — produces * on French AZERTY,
    -- # on UK, ç on Spanish, etc. This is the physical key sway calls "asterisk".
    , ((m, kBackslash),            toggleScratchpad "notes"
                                       (terminal conf ++ " -e nvim ~/Notes"))

    -- Per-output workspace cycling (Sway's prev_on_output / next_on_output)
    , ((m, kComma),                cycleOnOutput Prev)
    , ((m, kSemicolon),            cycleOnOutput Next)

    -- Global workspace cycling
    , ((m .|. shiftMask, kComma),      cycleGlobal Prev)
    , ((m .|. shiftMask, kSemicolon),  cycleGlobal Next)
    ]
    ++
    -- Workspaces 1-10: Mod + number row
    [ ((m, key), affinityView ws)
    | (ws, key) <- zip wsNames numKeys
    ]
    ++
    [ ((m .|. shiftMask, key), affinityShift ws)
    | (ws, key) <- zip wsNames numKeys
    ]
    ++
    -- Workspaces 11-20: Mod + Ctrl + number row
    [ ((m .|. controlMask, key), affinityView ws)
    | (ws, key) <- zip (drop 10 wsNames) numKeys
    ]
    ++
    [ ((m .|. shiftMask .|. controlMask, key), affinityShift ws)
    | (ws, key) <- zip (drop 10 wsNames) numKeys
    ]
  where
    m = modMask conf
    wsNames = mcWorkspaces conf
    numKeys = [k1, k2, k3, k4, k5, k6, k7, k8, k9, k0]
