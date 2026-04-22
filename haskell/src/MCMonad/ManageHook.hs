{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module MCMonad.ManageHook
    ( -- * Types
      ManageHook
    , Query(..)
      -- * Running hooks
    , runManageHook
      -- * Combinators
    , composeAll, composeOne
    , idHook
    , (-->), (=?), (<&&>), (<||>), (<+>)
      -- * Predicates
    , className, appName, title, bundleId
    , isDialog, isFixedSize, hasCloseButton, hasFullscreenButton
    , subrole
      -- * Actions
    , doFloat, doShift, doIgnore
      -- * Default
    , defaultManageHook
    ) where

import Control.Monad.Reader
import Data.Monoid (Endo(..))
import Data.Text (Text)
import qualified XMonad.StackSet as W

import MCMonad.Core
import MCMonad.IPC (WindowInfo(..))

-- ---------------------------------------------------------------------------
-- Types

-- | A query on a newly created window. Has access to the 'WindowInfo'
-- provided by the Swift daemon and can run 'M' actions.
newtype Query a = Query (ReaderT WindowInfo M a)
    deriving (Functor, Applicative, Monad, MonadIO)

-- | A manage hook: given window info, produce a monoid of 'WindowSet'
-- transformations. Uses 'Endo' so that hooks compose naturally via 'Semigroup'
-- and 'Monoid' -- matching xmonad's pattern exactly.
type ManageHook = Query (Endo WindowSet)

instance Semigroup a => Semigroup (Query a) where
    Query a <> Query b = Query $ (<>) <$> a <*> b

instance Monoid a => Monoid (Query a) where
    mempty = Query $ return mempty

-- ---------------------------------------------------------------------------
-- Running hooks

-- | Run a manage hook against a window, producing the 'WindowSet'
-- transformation.
runManageHook :: ManageHook -> WindowInfo -> M (Endo WindowSet)
runManageHook (Query q) wi = runReaderT q wi

-- ---------------------------------------------------------------------------
-- Combinators

-- | Compose a list of manage hooks. All matching hooks are applied in order.
composeAll :: [ManageHook] -> ManageHook
composeAll = mconcat

-- | Try each hook in order, using the first one that returns a non-identity
-- transformation. Returns 'mempty' if none match.
composeOne :: [Query (Maybe (Endo WindowSet))] -> ManageHook
composeOne [] = mempty
composeOne (q:qs) = Query $ do
    Query inner <- return q
    result <- inner
    case result of
        Just endo -> return endo
        Nothing   -> let Query rest = composeOne qs in rest

-- | Identity hook -- does nothing.
idHook :: ManageHook
idHook = mempty

-- | If the predicate matches, apply the action. This is the primary hook
-- combinator, matching xmonad's @==>@.
(-->) :: Query Bool -> ManageHook -> ManageHook
p --> f = do
    b <- p
    if b then f else mempty

infixr 0 -->

-- | Test equality of a query result.
(=?) :: Eq a => Query a -> a -> Query Bool
q =? x = (== x) <$> q

infix 4 =?

-- | Logical AND of two 'Query Bool' values.
(<&&>) :: Query Bool -> Query Bool -> Query Bool
(<&&>) = liftA2 (&&)

infixr 3 <&&>

-- | Logical OR of two 'Query Bool' values.
(<||>) :: Query Bool -> Query Bool -> Query Bool
(<||>) = liftA2 (||)

infixr 2 <||>

-- | Combine two manage hooks: both are applied.
(<+>) :: ManageHook -> ManageHook -> ManageHook
(<+>) = (<>)

infixr 5 <+>

-- ---------------------------------------------------------------------------
-- Predicates (selectors)

-- | Query the window title.
title :: Query (Maybe Text)
title = Query $ asks wiTitle

-- | Query the application name (e.g. "Safari").
appName :: Query (Maybe Text)
appName = Query $ asks wiAppName

-- | Query the bundle identifier (e.g. "com.apple.Safari").
-- On macOS this is the closest analogue to xmonad's @className@.
bundleId :: Query (Maybe Text)
bundleId = Query $ asks wiBundleId

-- | Query the class name. On macOS this maps to the bundle identifier;
-- provided for xmonad API compatibility.
className :: Query (Maybe Text)
className = bundleId

-- | Query the AX subrole (e.g. "AXStandardWindow", "AXDialog").
subrole :: Query (Maybe Text)
subrole = Query $ asks wiSubrole

-- | Is this window a dialog?
isDialog :: Query Bool
isDialog = Query $ asks wiIsDialog

-- | Is this window fixed-size (min size == max size)?
isFixedSize :: Query Bool
isFixedSize = Query $ asks wiIsFixedSize

-- | Does this window have a close button?
hasCloseButton :: Query Bool
hasCloseButton = Query $ asks wiHasCloseButton

-- | Does this window have a fullscreen/zoom button?
hasFullscreenButton :: Query Bool
hasFullscreenButton = Query $ asks wiHasFullscreenButton

-- ---------------------------------------------------------------------------
-- Actions

-- | Float the window at its current frame position. Converts the window's
-- absolute frame to a 'W.RationalRect' relative to the screen.
--
-- Note: since we don't know the screen geometry at manage-hook time, we
-- store a unit RationalRect (0, 0, 1, 1) and let 'Operations.windows'
-- resolve it. A more precise version would require screen info in the Query.
doFloat :: ManageHook
doFloat = Query $ do
    wi <- ask
    let wr = WindowRef (wiWindowId wi) (wiPid wi)
    return $ Endo $ W.float wr (W.RationalRect 0 0 1 1)

-- | Shift the window to the named workspace.
doShift :: String -> ManageHook
doShift ws = Query $ do
    wi <- ask
    let wr = WindowRef (wiWindowId wi) (wiPid wi)
    return $ Endo $ \wset -> W.shiftWin ws wr wset

-- | Ignore the window: remove it from the 'WindowSet' entirely so it is
-- not managed. The window will keep its original position.
doIgnore :: ManageHook
doIgnore = Query $ do
    wi <- ask
    let wr = WindowRef (wiWindowId wi) (wiPid wi)
    return $ Endo $ W.delete' wr

-- ---------------------------------------------------------------------------
-- Default manage hook

-- | Default window classification heuristics, derived from OmniWM's
-- WindowDecisionKernel. Dialogs, fixed-size windows, and windows without
-- a fullscreen button are floated.
defaultManageHook :: ManageHook
defaultManageHook = composeAll
    [ isDialog                          --> doFloat
    , isFixedSize                       --> doFloat
    , fmap not hasFullscreenButton      --> doFloat
    ]
