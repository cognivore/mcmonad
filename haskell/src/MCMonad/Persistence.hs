{-# LANGUAGE DeriveGeneric #-}

-- |
-- = mcmonad persistence
--
-- macOS gives us exactly one stable identifier for a window: the
-- pair @(CGWindowID, PID)@ — both supplied by the WindowServer and
-- the owning process, both unchanging for the lifetime of those
-- objects. mcmonad uses this pair, and only this pair, as window
-- identity for persistence.
--
-- This is sufficient for every restart scenario where mcmonad is
-- responsible for state: Mod-q recompile, mcmonad-core daemon
-- restart, launchd kick, both processes restarting at once. In
-- those cases the WindowServer keeps running, so CGWindowIDs and
-- PIDs are preserved; mcmonad re-queries the live window list, the
-- saved identities match by exact equality, and every window
-- returns to the workspace it was on.
--
-- It is **not** sufficient for logout / reboot. The WindowServer
-- dies; apps die; the windows that come back after login are new
-- objects with new identities. There is no foundational identity
-- that bridges that gap — only synthetic identity (titleHash,
-- per-app fingerprints) can, and synthetic identity is always
-- heuristic and surprising in the degenerate cases (multiple
-- empty-titled terminals, multiple browser windows). mcmonad
-- explicitly does not try. After logout / reboot, every window is
-- a fresh window and the manage hook places it according to the
-- user's @mcmonad.hs@ config.
--
-- See @~/Journals/incidents/20260601-mcmonad-multi-window-focus/@
-- for the post-mortem covering the synthetic-identity attempt
-- (commits @d60a605..815bea0@) and why it was reverted.
module MCMonad.Persistence
    ( -- * Persistence format
      SerialState(..)
    , SerStack(..)
    , persistenceVersion
      -- * Snapshot / restore
    , windowSetToSerial
    , serialToWindowSet
    ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified XMonad.StackSet as W

import MCMonad.Core (WindowRef(..), ScreenId(..), ScreenDetail(..), Timer(..))

-- ---------------------------------------------------------------------------
-- Persistence format
--
-- The on-disk shape is the same StackSet structure mcmonad already
-- has, but split into a plain @Show@-able value for @Read@-back.
-- The window type is the polymorphic parameter so the tests can
-- exercise the rebuilder without constructing a 'MCMonad.Core.Layout'.

-- | Persistence format version. Bumped whenever the on-disk schema
-- changes in a way older parsers can't tolerate. mcmonad reads
-- 'ssVersion' on load; any mismatch or parse failure renames the
-- stale file aside and starts fresh.
persistenceVersion :: Int
persistenceVersion = 3

-- | A workspace stack zipper, generalised over the window type.
-- 'ssUp' is reverse-ordered relative to display order, matching
-- @XMonad.StackSet.Stack@'s convention.
data SerStack a = SerStack
    { ssFocus :: !a
    , ssUp    :: ![a]
    , ssDown  :: ![a]
    } deriving (Eq, Show, Read, Functor, Foldable, Traversable)

-- | A serialisable snapshot of the WindowSet. The window type is a
-- parameter so the test suite can use a placeholder; the on-disk
-- form always carries 'WindowRef'.
data SerialState a = SerialState
    { ssVersion    :: !Int
      -- ^ 'persistenceVersion' at the time this snapshot was written.
    , ssStacks     :: ![(String, Maybe (SerStack a))]
      -- ^ Per-workspace zipper, keyed by workspace tag.
    , ssCurrentTag :: !String
      -- ^ Tag of the workspace that held focus.
    , ssFloating   :: ![(a, (Rational, Rational, Rational, Rational))]
      -- ^ Floating window positions as (x, y, w, h) rationals.
    , ssAffinity   :: ![(String, Int)]
      -- ^ Serialised workspace -> screen-id affinity map.
    , ssTimers     :: ![Timer]
      -- ^ Running countdown timers, so they resume after a restart.
      -- Independent of the window type @a@. See "MCMonad.Core".'Timer'.
    , ssNextTimerId :: !Int
      -- ^ The brain's monotonic timer-id counter ('MCMonad.Core.nextTimerId'),
      -- saved so restored ids never collide with freshly-issued ones.
    } deriving (Eq, Show, Read)
-- Functor/Foldable/Traversable not derivable here because 'a' sits
-- in the first slot of the 'ssFloating' tuple. We don't need a
-- generic fmap; substitution lives at the call sites.

-- ---------------------------------------------------------------------------
-- Snapshot

-- | Take a 'WindowSet' (plus its affinity map and the running timer
-- list) to a 'SerialState'. All windows are referenced by 'WindowRef'
-- — the on-disk identity.
windowSetToSerial
    :: W.StackSet String l WindowRef ScreenId ScreenDetail
    -> Map.Map String ScreenId
    -> [Timer]                             -- ^ from @MState.timers@
    -> Int                                 -- ^ from @MState.nextTimerId@
    -> SerialState WindowRef
windowSetToSerial ws aff timers' nextTimerId' = SerialState
    { ssVersion    = persistenceVersion
    , ssStacks     = map serWsp allWsps
    , ssCurrentTag = W.tag (W.workspace (W.current ws))
    , ssFloating   =
        [ (w, (rx, ry, rw, rh))
        | (w, W.RationalRect rx ry rw rh) <- Map.toList (W.floating ws)
        -- Never persist a floating entry for a window that isn't in
        -- some stack. Float-only entries are leaks ('W.float' inserts
        -- unconditionally; historical 'W.delete'' call sites skipped
        -- the floating map) and grew mcmonad.state by hundreds of dead
        -- windows before this guard existed.
        , W.member w ws
        ]
    , ssAffinity   = [(tag, n) | (tag, S n) <- Map.toList aff]
    , ssTimers     = timers'
    , ssNextTimerId = nextTimerId'
    }
  where
    allWsps = map W.workspace (W.current ws : W.visible ws) ++ W.hidden ws
    serWsp wsp = (W.tag wsp, fmap serStack (W.stack wsp))
    serStack (W.Stack f u d) = SerStack f u d

-- ---------------------------------------------------------------------------
-- Restore

-- | Rebuild a 'WindowSet' from a 'SerialState', the config's layout,
-- the config's workspace list, and the current screen geometry.
--
-- Screen assignment respects 'ssAffinity' (workspace tag → screen
-- index) so each physical monitor keeps the workspace it had at save
-- time. Workspaces that affinity doesn't cover fall back to config
-- order, with 'ssCurrentTag' pulled to the front so empty-affinity
-- saves still put the focused tag on the first screen.
--
-- The current screen is the assignment whose tag equals
-- 'ssCurrentTag'; if that tag was renamed or removed from the config
-- the first assignment is used instead.
--
-- Polymorphic in the layout type so the test suite can pass any
-- placeholder; production callers pass the real 'MCMonad.Core.Layout'.
serialToWindowSet
    :: l                                   -- ^ from @config.layoutHook@
    -> [String]                            -- ^ all workspace tags from config
    -> [(ScreenId, ScreenDetail)]          -- ^ live screen geometry
    -> SerialState WindowRef
    -> W.StackSet String l WindowRef ScreenId ScreenDetail
serialToWindowSet layout allTags screens saved = pruneFloating built
  where
    built = W.StackSet
        { W.current  = currentSc
        , W.visible  = visibleScs
        , W.hidden   = hiddenWSs
        , W.floating = Map.fromList
            [ (w, W.RationalRect rx ry rw rh)
            | (w, (rx, ry, rw, rh)) <- ssFloating saved
            ]
        }

    -- Mirror of the save-side guard in 'windowSetToSerial': a snapshot
    -- written by an older binary (or one whose stacks were filtered to
    -- the current config's tags) may carry floating entries for windows
    -- that appear in no stack. Restoring them would resurrect the leak,
    -- so keep only entries whose window is a member of the rebuilt set.
    pruneFloating ws = ws
        { W.floating = Map.filterWithKey (\w _ -> W.member w ws)
                                         (W.floating ws)
        }
    savedMap = Map.fromList (ssStacks saved)
    mkWorkspace tag = W.Workspace tag layout $ case Map.lookup tag savedMap of
        Just (Just s) -> Just (W.Stack (ssFocus s) (ssUp s) (ssDown s))
        _             -> Nothing

    -- Pre-built affinity lookup: ScreenId index → tag at save time.
    -- Drop entries whose tag is no longer in the config or whose screen is
    -- no longer present. Otherwise the tag is removed from the fallback pool
    -- without ever receiving a screen, deleting that workspace on restore.
    affByScreen :: Map.Map Int String
    affByScreen = Map.fromList
        [ (sid, tag)
        | (tag, sid) <- ssAffinity saved
        , tag `elem` allTags
        , sid `Set.member` liveScreenIds
        ]
    liveScreenIds = Set.fromList [i | (S i, _) <- screens]
    affTags = Map.elems affByScreen

    -- Tags not claimed by affinity, with 'ssCurrentTag' moved to the
    -- front when it's still unclaimed. Preserves "current tag on first
    -- screen" for empty-affinity saves.
    poolInit =
        let unused = filter (`notElem` affTags) allTags
            cur    = ssCurrentTag saved
        in if cur `elem` unused
            then cur : filter (/= cur) unused
            else unused

    -- For each present screen, in ScreenId order, pick the tag that
    -- had affinity for that index, otherwise pop from the pool.
    (assignments, leftover) = foldl' assignOne ([], poolInit) screens
      where
        assignOne (acc, pool) (sid@(S i), sd) =
            case Map.lookup i affByScreen of
                Just tag -> (acc ++ [(sid, sd, tag)], pool)
                Nothing  -> case pool of
                    (t:rest') -> (acc ++ [(sid, sd, t)], rest')
                    []        -> error
                        "MCMonad.Persistence.serialToWindowSet: \
                        \fewer config workspaces than screens"

    mkScreen (sid, sd, tag) = W.Screen (mkWorkspace tag) sid sd
    (currentSc, visibleScs) =
        case break (\(_, _, t) -> t == ssCurrentTag saved) assignments of
            (before, curr:after) ->
                (mkScreen curr, map mkScreen (before ++ after))
            (_, []) -> case assignments of
                (a:rest') -> (mkScreen a, map mkScreen rest')
                []        -> error
                    "MCMonad.Persistence.serialToWindowSet: no screens"

    hiddenWSs = map mkWorkspace leftover
