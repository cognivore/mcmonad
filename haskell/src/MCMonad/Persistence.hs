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
--
-- == Restore is lazy
--
-- Matching is exact, but it is not a one-shot test. A saved identity
-- that is missing from mcmonad-core's enumeration is __not__ concluded
-- dead: the enumeration is a snapshot of what SkyLight and AX would
-- answer at that instant, and on 2026-08-28 that answer was empty for
-- a daemon restarted while the display was asleep. Under the old
-- one-shot rule every saved window was deleted, the emptied snapshot
-- was written straight back to disk, and the same windows were
-- re-adopted as brand-new ones onto the current workspace two seconds
-- later — every workspace assignment gone in one write.
--
-- Now a saved window the daemon did not confirm is held aside as a
-- 'PendingWindow' ('partitionPending'): outside the live 'WindowSet',
-- so it is never laid out, focused or parked as a ghost, but with
-- enough context to go back exactly where it was ('placePending') the
-- moment the daemon reports it. Pending windows are persisted on their
-- workspaces ('mergePending' runs before every save), so the on-disk
-- snapshot always records where every window belongs and a second
-- restart re-derives the same pending set. A pending entry is retired
-- only on positive evidence — its process is gone (checked at restore
-- in "MCMonad.Main") or the daemon reports the window destroyed —
-- never on the strength of an absence.
module MCMonad.Persistence
    ( -- * Persistence format
      SerialState(..)
    , SerStack(..)
    , persistenceVersion
      -- * Snapshot / restore
    , windowSetToSerial
    , serialToWindowSet
      -- * Lazy restore
    , partitionPending
    , placePending
    , mergePending
    ) where

import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import qualified XMonad.StackSet as W

import MCMonad.Core
    ( WindowRef(..), ScreenId(..), ScreenDetail(..), Timer(..)
    , PendingWindow(..)
    )

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

-- ---------------------------------------------------------------------------
-- Lazy restore

-- | Split a rebuilt 'WindowSet' into the part the daemon confirmed and
-- the windows it did not. Confirmed windows stay; every other saved
-- window is deleted from the set (the full 'W.delete', so its floating
-- entry goes too) and recorded as a 'PendingWindow' carrying its
-- workspace, its saved predecessors, whether it held the focus, and
-- its floating rectangle — everything 'placePending' needs to put it
-- back.
partitionPending
    :: Ord a
    => Set.Set a
       -- ^ the identities the daemon enumerated
    -> W.StackSet String l a sid sd
       -- ^ rebuilt from the snapshot, before any reconciliation
    -> (W.StackSet String l a sid sd, Map.Map a (PendingWindow a))
partitionPending live ws0 = (foldr W.delete ws0 absent, Map.fromList entries)
  where
    absent  = filter (`Set.notMember` live) (W.allWindows ws0)
    entries = [ (w, pendingFor w) | w <- absent ]
    pendingFor w =
        case W.findTag w ws0 >>= \t -> find ((== t) . W.tag) (W.workspaces ws0) of
            Just wsp ->
                let order = W.integrate' (W.stack wsp)
                in PendingWindow
                    { pwTag     = W.tag wsp
                    , pwBefore  = reverse (takeWhile (/= w) order)
                    , pwFocused = fmap W.focus (W.stack wsp) == Just w
                    , pwFloat   = rational <$> Map.lookup w (W.floating ws0)
                    }
            Nothing -> error
                "MCMonad.Persistence.partitionPending: \
                \window is in allWindows but on no workspace"
    rational (W.RationalRect x y w h) = (x, y, w, h)

-- | Put a pending window back on its workspace.
--
-- It is re-inserted directly after the nearest of its saved
-- predecessors that is present on that workspace, or at the top when
-- none is; if it held the workspace's focus at save time it takes the
-- focus back, otherwise the workspace's current focus is untouched.
-- The rule is order-independent: whichever subset of a workspace's
-- saved windows returns, in whatever order, ends up in the saved
-- relative order (see the @pending@ properties).
--
-- 'Nothing' when the workspace no longer exists — the caller treats
-- the window as new. A window that is already a member is left alone.
placePending
    :: Ord a
    => a
    -> PendingWindow a
    -> W.StackSet String l a sid sd
    -> Maybe (W.StackSet String l a sid sd)
placePending w pw ws
    | W.member w ws = Just ws
    | pwTag pw `notElem` map W.tag (W.workspaces ws) = Nothing
    | otherwise = Just (withFloat (W.mapWorkspace place ws))
  where
    place wsp
        | W.tag wsp == pwTag pw = wsp { W.stack = Just (insertBack (W.stack wsp)) }
        | otherwise             = wsp
    insertBack Nothing   = W.Stack w [] []
    insertBack (Just st) =
        let order  = W.integrate st
            anchor = find (`elem` order) (pwBefore pw)
            order' = case anchor of
                Nothing -> w : order
                Just a  -> let (before, rest) = break (== a) order
                           in before ++ a : w : drop 1 rest
            focus' = if pwFocused pw then w else W.focus st
        in stackAt focus' order'
    withFloat ws' = case pwFloat pw of
        Nothing           -> ws'
        Just (x, y, r, h) -> ws'
            { W.floating = Map.insert w (W.RationalRect x y r h) (W.floating ws') }

-- | Rebuild a zipper from a display-order list and the element to
-- focus, which must be in the list.
stackAt :: Eq a => a -> [a] -> W.Stack a
stackAt f xs =
    let (before, rest) = break (== f) xs
    in W.Stack f (reverse before) (drop 1 rest)

-- | Fold every pending window back onto its workspace. Used by the save
-- path so the persisted snapshot carries pending windows where they
-- belong; entries whose workspace is gone are skipped.
mergePending
    :: Ord a
    => Map.Map a (PendingWindow a)
    -> W.StackSet String l a sid sd
    -> W.StackSet String l a sid sd
mergePending pend ws = Map.foldrWithKey step ws pend
  where
    step w pw acc = fromMaybe acc (placePending w pw acc)
