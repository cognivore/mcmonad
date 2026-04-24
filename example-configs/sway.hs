-- | Sway/i3-style configuration for mcmonad.
--
-- Replicates the keybindings from cstnix1's sway.nix:
--   - Option (Mod4/Super) as modifier
--   - i3-style tree layout with splith/splitv/tabbed
--   - 20 workspaces (1-10 on number row, 11-20 with Ctrl)
--   - Affinity-aware workspace switching (Sway behaviour)
--   - Per-output cycling on comma/semicolon
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
    , mcWorkspaces    = map show [1 :: Int .. 20]
    , focusFollowsMouse = False
    , borderWidth     = 0
    })
    { mcKeys = cstKeys }

-- | Keybindings matching cstnix1's sway config.
cstKeys :: MConfig Layout -> Map.Map (Modifiers, KeyCode) (M ())
cstKeys conf = Map.fromList $
    -- Terminal
    [ ((m, kReturn),               spawn (terminal conf))

    -- Kill / restart
    , ((m .|. shiftMask, kQ),      kill)
    , ((m .|. shiftMask, kR),      restart)

    -- Focus (stack cycling — closest to Sway's directional focus)
    , ((m, kJ),                    windows focusDown)
    , ((m, kK),                    windows focusUp)
    , ((m, kH),                    sendMessage XMonad.Shrink)
    , ((m, kL),                    sendMessage XMonad.Expand)

    -- Move windows in the stack
    , ((m .|. shiftMask, kJ),      windows swapDown)
    , ((m .|. shiftMask, kK),      windows swapUp)

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
    ++
    -- Screen focus (Mod-{w,e,r})
    [ ((mask, key), screenWorkspace sc >>= maybe (return ()) (windows . action))
    | (key, sc) <- zip [kW, kE, kR] [0..]
    , (action, mask) <- [(view, m), (shift, m .|. shiftMask)]
    ]
  where
    m = modMask conf
    wsNames = mcWorkspaces conf
    numKeys = [k1, k2, k3, k4, k5, k6, k7, k8, k9, k0]
