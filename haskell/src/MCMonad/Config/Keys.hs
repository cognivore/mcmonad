-- | Complete Carbon virtual keycode definitions for macOS.
--
-- These are physical key positions, not characters. The same keycode
-- applies regardless of keyboard layout (QWERTY, AZERTY, Dvorak, etc.).
-- For example, 'k1' is always the physical \"1\" key in the number row,
-- even though it produces \"&\" on a French AZERTY layout.
--
-- Import this module in your @~\/.config\/mcmonad\/mcmonad.hs@ when you
-- need keycode constants for custom keybindings:
--
-- @
-- import MCMonad
-- import MCMonad.Config.Keys
-- @
module MCMonad.Config.Keys
    ( -- * Type
      KeyCode
      -- * Letter keys
    , kA, kB, kC, kD, kE, kF, kG, kH, kI, kJ
    , kK, kL, kM, kN, kO, kP, kQ, kR, kS, kT
    , kU, kV, kW, kX, kY, kZ
      -- * Number keys (top row)
    , k0, k1, k2, k3, k4, k5, k6, k7, k8, k9
      -- * Function keys
    , kF1, kF2, kF3, kF4, kF5, kF6, kF7, kF8, kF9, kF10
    , kF11, kF12, kF13, kF14, kF15, kF16, kF17, kF18, kF19
      -- * Arrow keys
    , kLeft, kRight, kUp, kDown
      -- * Navigation
    , kHome, kEnd, kPageUp, kPageDown
      -- * Special keys
    , kReturn, kTab, kSpace, kEscape, kDelete, kForwardDelete
      -- * Punctuation and symbols
    , kComma, kPeriod, kSemicolon, kQuote, kGrave
    , kMinus, kEqual, kSlash, kBackslash
    , kLeftBracket, kRightBracket
      -- * Keypad
    , kKeypad0, kKeypad1, kKeypad2, kKeypad3, kKeypad4
    , kKeypad5, kKeypad6, kKeypad7, kKeypad8, kKeypad9
    , kKeypadDecimal, kKeypadMultiply, kKeypadPlus
    , kKeypadMinus, kKeypadDivide, kKeypadEnter
    , kKeypadEquals, kKeypadClear
    ) where

import Data.Word (Word32)

-- | A Carbon virtual key code (physical key position on macOS).
type KeyCode = Word32

-- ---------------------------------------------------------------------------
-- Letter keys (kVK_ANSI_*)

kA, kB, kC, kD, kE, kF, kG, kH, kI, kJ :: KeyCode
kA = 0x00; kB = 0x0B; kC = 0x08; kD = 0x02; kE = 0x0E
kF = 0x03; kG = 0x05; kH = 0x04; kI = 0x22; kJ = 0x26

kK, kL, kM, kN, kO, kP, kQ, kR, kS, kT :: KeyCode
kK = 0x28; kL = 0x25; kM = 0x2E; kN = 0x2D; kO = 0x1F
kP = 0x23; kQ = 0x0C; kR = 0x0F; kS = 0x01; kT = 0x11

kU, kV, kW, kX, kY, kZ :: KeyCode
kU = 0x20; kV = 0x09; kW = 0x0D; kX = 0x07; kY = 0x10; kZ = 0x06

-- ---------------------------------------------------------------------------
-- Number keys — top row (kVK_ANSI_*)
-- On AZERTY these are &é"'(-è_çà but the keycodes are the same.

k0, k1, k2, k3, k4, k5, k6, k7, k8, k9 :: KeyCode
k1 = 0x12; k2 = 0x13; k3 = 0x14; k4 = 0x15; k5 = 0x17
k6 = 0x16; k7 = 0x1A; k8 = 0x1C; k9 = 0x19; k0 = 0x1D

-- ---------------------------------------------------------------------------
-- Function keys (kVK_F*)

kF1, kF2, kF3, kF4, kF5, kF6, kF7, kF8, kF9, kF10 :: KeyCode
kF1 = 0x7A; kF2 = 0x78; kF3 = 0x63; kF4 = 0x76; kF5 = 0x60
kF6 = 0x61; kF7 = 0x62; kF8 = 0x64; kF9 = 0x65; kF10 = 0x6D

kF11, kF12, kF13, kF14, kF15, kF16, kF17, kF18, kF19 :: KeyCode
kF11 = 0x67; kF12 = 0x6F; kF13 = 0x69; kF14 = 0x6B; kF15 = 0x71
kF16 = 0x6A; kF17 = 0x40; kF18 = 0x4F; kF19 = 0x50

-- ---------------------------------------------------------------------------
-- Arrow keys (kVK_*Arrow)

kLeft, kRight, kUp, kDown :: KeyCode
kLeft = 0x7B; kRight = 0x7C; kUp = 0x7E; kDown = 0x7D

-- ---------------------------------------------------------------------------
-- Navigation keys

kHome, kEnd, kPageUp, kPageDown :: KeyCode
kHome = 0x73; kEnd = 0x77; kPageUp = 0x74; kPageDown = 0x79

-- ---------------------------------------------------------------------------
-- Special keys

kReturn, kTab, kSpace, kEscape, kDelete, kForwardDelete :: KeyCode
kReturn = 0x24; kTab = 0x30; kSpace = 0x31
kEscape = 0x35; kDelete = 0x33; kForwardDelete = 0x75

-- ---------------------------------------------------------------------------
-- Punctuation and symbols (kVK_ANSI_*)

kComma, kPeriod, kSemicolon, kQuote, kGrave :: KeyCode
kComma = 0x2B; kPeriod = 0x2F; kSemicolon = 0x29
kQuote = 0x27; kGrave = 0x32

kMinus, kEqual, kSlash, kBackslash :: KeyCode
kMinus = 0x1B; kEqual = 0x18; kSlash = 0x2C; kBackslash = 0x2A

kLeftBracket, kRightBracket :: KeyCode
kLeftBracket = 0x21; kRightBracket = 0x1E

-- ---------------------------------------------------------------------------
-- Keypad (kVK_ANSI_Keypad*)

kKeypad0, kKeypad1, kKeypad2, kKeypad3, kKeypad4 :: KeyCode
kKeypad0 = 0x52; kKeypad1 = 0x53; kKeypad2 = 0x54
kKeypad3 = 0x55; kKeypad4 = 0x56

kKeypad5, kKeypad6, kKeypad7, kKeypad8, kKeypad9 :: KeyCode
kKeypad5 = 0x57; kKeypad6 = 0x58; kKeypad7 = 0x59
kKeypad8 = 0x5B; kKeypad9 = 0x5C

kKeypadDecimal, kKeypadMultiply, kKeypadPlus :: KeyCode
kKeypadDecimal = 0x41; kKeypadMultiply = 0x43; kKeypadPlus = 0x45

kKeypadMinus, kKeypadDivide, kKeypadEnter :: KeyCode
kKeypadMinus = 0x4E; kKeypadDivide = 0x4B; kKeypadEnter = 0x4C

kKeypadEquals, kKeypadClear :: KeyCode
kKeypadEquals = 0x51; kKeypadClear = 0x47
