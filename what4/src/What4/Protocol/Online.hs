{-# LANGUAGE OverloadedLists #-}
{- |
Module      : What4.Protocol.Online
Copyright   : (c) Galois, Inc 2018
License     : BSD3
Maintainer  : Rob Dockins <rdockins@galois.com>

This module defines an API for interacting with
solvers that support online interaction modes.

-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
module What4.Protocol.Online
  ( OnlineSolver(..)
  , SolverProcess(..)
  , killSolver
  , push
  , pop
  , reset
  , inNewFrame
  , check
  , checkAndGetModel
  , checkWithAssumptions
  , checkWithAssumptionsAndModel
  , getModel
  , getUnsatCore
  , getUnsatAssumptions
  , getSatResult
  , checkSatisfiable
  , checkSatisfiableWithModel

  -- Version checking
  , checkSolverVersion
  , checkSolverVersion'
  , ppSolverVersionCheckError
  , ppSolverVersionError
  ) where

import           Control.Exception
                   ( SomeException(..), catch, try, displayException )
import           Control.Monad ( unless )
import           Control.Monad (void, forM)
import           Control.Monad.Catch ( MonadMask, bracket_ )
import           Control.Monad.IO.Class ( MonadIO, liftIO )
import           Data.IORef
import           Data.Text (Text)
import qualified Data.Text.Lazy as LazyText
import           System.Exit
import           System.IO
import qualified System.IO.Streams as Streams
import           System.Process
                   (ProcessHandle, interruptProcessGroupOf, waitForProcess)
import           Text.PrettyPrint.ANSI.Leijen hiding ((<$>), (<>))

import           What4.Expr
import           What4.Interface (SolverEvent(..))
import           What4.ProblemFeatures
import           What4.Protocol.SMTWriter
import           What4.SatResult
import           What4.Utils.HandleReader

import qualified Data.Map.Strict as Map
import           Data.Map.Strict (Map)
import           Data.Versions (Version(..))
import qualified Data.Versions as Versions
import qualified Text.PrettyPrint.ANSI.Leijen as PP

-- | This class provides an API for starting and shutting down
--   connections to various different solvers that support
--   online interaction modes.
class SMTReadWriter solver => OnlineSolver scope solver where
  -- | Start a new solver process attached to the given `ExprBuilder`.
  startSolverProcess    :: ProblemFeatures -> Maybe Handle -> ExprBuilder scope st fs -> IO (SolverProcess scope solver)

  -- | Shut down a solver process.  The process will be asked to shut down in
  --   a "polite" way, e.g., by sending an `(exit)` message, or by closing
  --   the process's `stdin`.  Use `killProcess` instead to shutdown a process
  --   via a signal.
  shutdownSolverProcess :: SolverProcess scope solver -> IO (ExitCode, LazyText.Text)

-- | A live connection to a running solver process.
data SolverProcess scope solver = SolverProcess
  { solverConn  :: !(WriterConn scope solver)
    -- ^ Writer for sending commands to the solver

  , solverHandle :: !ProcessHandle
    -- ^ Handle to the solver process

  , solverStdin :: !(Streams.OutputStream Text)
    -- ^ Standard in for the solver process.

  , solverResponse :: !(Streams.InputStream Text)
    -- ^ Wrap the solver's stdout, for easier parsing of responses.

  , solverStderr :: !HandleReader
    -- ^ Standard error for the solver process

  , solverEvalFuns :: !(SMTEvalFunctions solver)
    -- ^ The functions used to parse values out of models.

  , solverLogFn :: SolverEvent -> IO ()

  , solverName :: String

  , solverEarlyUnsat :: IORef (Maybe Int)
    -- ^ Some solvers will enter an 'UNSAT' state early, if they can easily
    --   determine that context is unsatisfiable.  If this IORef contains
    --   an integer value, it indicates how many \"pop\" operations need to
    --   be performed to return to a potentially satisfiable state.
    --   A @Just 0@ state indicates the special case that the top-level context
    --   is unsatisfiable, and must be \"reset\".
  }


-- | An impolite way to shut down a solver.  Prefer to use
--   `shutdownSolverProcess`, unless the solver is unresponsive
--   or in some unrecoverable error state.
killSolver :: SolverProcess t solver -> IO ()
killSolver p =
  do catch (interruptProcessGroupOf (solverHandle p)) (\(_ :: SomeException) -> return ())
     void $ waitForProcess (solverHandle p)

-- | Check if the given formula is satisfiable in the current
--   solver state, without requesting a model.  This is done in a
--   fresh frame, which is exited after the check call.
checkSatisfiable ::
  SMTReadWriter solver =>
  SolverProcess scope solver ->
  String ->
  BoolExpr scope ->
  IO (SatResult () ())
checkSatisfiable proc rsn p =
  readIORef (solverEarlyUnsat proc) >>= \case
    Just _  -> return (Unsat ())
    Nothing ->
      let conn = solverConn proc in
      inNewFrame proc $
        do assume conn p
           check proc rsn

-- | Check if the formula is satisifiable in the current
--   solver state.  This is done in a
--   fresh frame, which is exited after the continuation
--   complets. The evaluation function can be used to query the model.
--   The model is valid only in the given continuation.
checkSatisfiableWithModel ::
  SMTReadWriter solver =>
  SolverProcess scope solver ->
  String ->
  BoolExpr scope ->
  (SatResult (GroundEvalFn scope) () -> IO a) ->
  IO a
checkSatisfiableWithModel proc rsn p k =
  readIORef (solverEarlyUnsat proc) >>= \case
    Just _  -> k (Unsat ())
    Nothing ->
      let conn = solverConn proc in
      inNewFrame proc $
        do assume conn p
           checkAndGetModel proc rsn >>= k

-----------------------------------------------------------------
-- Checking solver version bounds

mkChunks :: [Word] -> [Versions.VChunk]
mkChunks = map ((:[]) . Versions.Digits)

-- | The minimum (inclusive) version bound for a given solver.
--
-- The keys come from @'smtWriterName'@ in @'WriterConn'@.
-- See also https://github.com/GaloisInc/crucible/issues/194
solverMinVersions :: Map String Version
solverMinVersions =
  [ -- TODO: Why is this verion required?
    ( "yices"
    , Version { _vEpoch = Nothing, _vChunks = mkChunks [2, 6, 1], _vRel = []}
    )
  ]

-- | The maximum (non-inclusive) version bound for a given solver.
--
-- The keys come from @'smtWriterName'@ in @'WriterConn'@.
solverMaxVersions :: Map String Version
solverMaxVersions = []

-- | Things that can go wrong while checking which solver version we've got
data SolverVersionCheckError =
  UnparseableVersion Versions.ParsingError

ppSolverVersionCheckError :: SolverVersionCheckError -> PP.Doc
ppSolverVersionCheckError =
  (PP.text "Unexpected error while checking solver version: " PP.<$$>) .
  \case
    UnparseableVersion parseErr -> PP.cat $ map PP.text
      [ "Couldn't parse solver version number: "
      , show parseErr
      ]

data SolverVersionError =
  SolverVersionError
  { vMin :: Maybe Version
  , vMax :: Maybe Version
  , vActual :: Version
  }
  deriving (Eq, Ord)

ppSolverVersionError :: SolverVersionError -> PP.Doc
ppSolverVersionError err = PP.vcat $ map PP.text
  [ "Solver did not meet version bound restrictions: "
  , "Lower bound (inclusive): " ++ na (show <$> vMin err)
  , "Upper bound (non-inclusive): " ++ na (show <$> vMax err)
  , "Actual version: " ++ show (vActual err)
  ]
  where na (Just s) = s
        na Nothing  = "n/a"

-- | Ensure the solver's version falls within a known-good range.
checkSolverVersion' :: SMTReadWriter solver =>
  Map String Version {- ^ min version bounds (inclusive) -} ->
  Map String Version {- ^ max version bounds (non-inclusive) -} ->
  SolverProcess scope solver ->
  IO (Either SolverVersionCheckError (Maybe SolverVersionError))
checkSolverVersion' mins maxes proc =
  let conn = solverConn proc
      name = smtWriterName conn
      min0 = Map.lookup name mins
      max0 = Map.lookup name maxes
      verr = pure . Right . Just . SolverVersionError min0 max0
      done = pure (Right Nothing)
  in
    case (min0, max0) of
      (Nothing, Nothing) -> done
      (p, q) -> do
        addCommandNoAck conn (getVersionCommand conn)
        res <- smtVersionResult conn (solverResponse proc)
        case Versions.version res of
          Left e -> pure (Left (UnparseableVersion e))
          Right actualVer ->
            case (p, q) of
              (Nothing, Nothing) -> error "What4/Online: Impossible"
              (Nothing, Just maxVer) ->
                if actualVer < maxVer then done else verr actualVer
              (Just minVer, Nothing) ->
                if minVer <= actualVer then done else verr actualVer
              (Just minVer, Just maxVer) ->
                if minVer <= actualVer && actualVer < maxVer
                then done
                else verr actualVer


-- | Ensure the solver's version falls within a known-good range.
checkSolverVersion :: SMTReadWriter solver =>
  SolverProcess scope solver ->
  IO (Either SolverVersionCheckError (Maybe SolverVersionError))
checkSolverVersion =
  checkSolverVersion' solverMinVersions solverMaxVersions

  -- (smtWriterName conn)

--------------------------------------------------------------------------------
-- Basic solver interaction.

reset :: SMTReadWriter solver => SolverProcess scope solver -> IO ()
reset p =
  do let c = solverConn p
     resetEntryStack c
     writeIORef (solverEarlyUnsat p) Nothing
     addCommand c (resetCommand c)

-- | Push a new solver assumption frame.
push :: SMTReadWriter solver => SolverProcess scope solver -> IO ()
push p =
  readIORef (solverEarlyUnsat p) >>= \case
    Nothing -> do let c = solverConn p
                  pushEntryStack c
                  addCommand c (pushCommand c)
    Just i  -> writeIORef (solverEarlyUnsat p) $! (Just $! i+1)

-- | Pop a previous solver assumption frame.
pop :: SMTReadWriter solver => SolverProcess scope solver -> IO ()
pop p =
  readIORef (solverEarlyUnsat p) >>= \case
    Nothing -> do let c = solverConn p
                  popEntryStack c
                  addCommand c (popCommand c)
    Just i
      | i <= 1 -> do let c = solverConn p
                     popEntryStack c
                     writeIORef (solverEarlyUnsat p) Nothing
                     addCommand c (popCommand c)
      | otherwise -> writeIORef (solverEarlyUnsat p) $! (Just $! i-1)

-- | Perform an action in the scope of a solver assumption frame.
inNewFrame :: (MonadIO m, MonadMask m, SMTReadWriter solver) => SolverProcess scope solver -> m a -> m a
inNewFrame p = bracket_ (liftIO $ push p) (liftIO $ pop p)

checkWithAssumptions ::
  SMTReadWriter solver =>
  SolverProcess scope solver ->
  String ->
  [BoolExpr scope] ->
  IO ([Text], SatResult () ())
checkWithAssumptions proc rsn ps =
  do let conn = solverConn proc
     readIORef (solverEarlyUnsat proc) >>= \case
       Just _  -> return ([], Unsat ())
       Nothing ->
         do tms <- forM ps (mkFormula conn)
            nms <- forM tms (freshBoundVarName conn EqualityDefinition [] BoolTypeMap)
            solverLogFn proc
              SolverStartSATQuery
              { satQuerySolverName = solverName proc
              , satQueryReason = rsn
              }
            addCommandNoAck conn (checkWithAssumptionsCommand conn nms)
            sat_result <- getSatResult proc
            solverLogFn proc
              SolverEndSATQuery
              { satQueryResult = sat_result
              , satQueryError = Nothing
              }
            return (nms, sat_result)

checkWithAssumptionsAndModel ::
  SMTReadWriter solver =>
  SolverProcess scope solver ->
  String ->
  [BoolExpr scope] ->
  IO (SatResult (GroundEvalFn scope) ())
checkWithAssumptionsAndModel proc rsn ps =
  do (_nms, sat_result) <- checkWithAssumptions proc rsn ps
     case sat_result of
       Unknown -> return Unknown
       Unsat x -> return (Unsat x)
       Sat{} -> Sat <$> getModel proc

-- | Send a check command to the solver, and get the SatResult without asking
--   a model.
check :: SMTReadWriter solver => SolverProcess scope solver -> String -> IO (SatResult () ())
check p rsn =
  readIORef (solverEarlyUnsat p) >>= \case
    Just _  -> return (Unsat ())
    Nothing ->
      do let c = solverConn p
         solverLogFn p
           SolverStartSATQuery
           { satQuerySolverName = solverName p
           , satQueryReason = rsn
           }
         addCommandNoAck c (checkCommand c)
         sat_result <- getSatResult p
         solverLogFn p
           SolverEndSATQuery
           { satQueryResult = sat_result
           , satQueryError = Nothing
           }
         return sat_result

-- | Send a check command to the solver and get the model in the case of a SAT result.
checkAndGetModel :: SMTReadWriter solver => SolverProcess scope solver -> String -> IO (SatResult (GroundEvalFn scope) ())
checkAndGetModel yp rsn = do
  sat_result <- check yp rsn
  case sat_result of
    Unsat x -> return $! Unsat x
    Unknown -> return $! Unknown
    Sat () -> Sat <$> getModel yp

-- | Following a successful check-sat command, build a ground evaulation function
--   that will evaluate terms in the context of the current model.
getModel :: SMTReadWriter solver => SolverProcess scope solver -> IO (GroundEvalFn scope)
getModel p = smtExprGroundEvalFn (solverConn p)
             $ smtEvalFuns (solverConn p) (solverResponse p)

-- | After an unsatisfiable check-with-assumptions command, compute a set of the supplied
--   assumptions that (together with previous assertions) form an unsatisfiable core.
--   Note: the returned unsatisfiable set might not be minimal.  The boolean value
--   returned along with the name indicates if the assumption was negated or not:
--   @True@ indidcates a positive atom, and @False@ represents a negated atom.
getUnsatAssumptions :: SMTReadWriter solver => SolverProcess scope solver -> IO [(Bool,Text)]
getUnsatAssumptions proc =
  do let conn = solverConn proc
     unless (supportedFeatures conn `hasProblemFeature` useUnsatAssumptions) $
       fail $ show $ text (smtWriterName conn) <+> text "is not configured to produce UNSAT assumption lists"
     addCommandNoAck conn (getUnsatAssumptionsCommand conn)
     smtUnsatAssumptionsResult conn (solverResponse proc)

-- | After an unsatisfiable check-sat command, compute a set of the named assertions
--   that (together with all the unnamed assertions) form an unsatisfiable core.
--   Note: the returned unsatisfiable core might not be minimal.
getUnsatCore :: SMTReadWriter solver => SolverProcess scope solver -> IO [Text]
getUnsatCore proc =
  do let conn = solverConn proc
     unless (supportedFeatures conn `hasProblemFeature` useUnsatCores) $
       fail $ show $ text (smtWriterName conn) <+> text "is not configured to produce UNSAT cores"
     addCommandNoAck conn (getUnsatCoreCommand conn)
     smtUnsatCoreResult conn (solverResponse proc)

-- | Get the sat result from a previous SAT command.
getSatResult :: SMTReadWriter s => SolverProcess t s -> IO (SatResult () ())
getSatResult yp = do
  let ph = solverHandle yp
  let err_reader = solverStderr yp
  sat_result <- try (smtSatResult yp (solverResponse yp))
  case sat_result of
    Right ok -> return ok

    Left (SomeException e) ->
       do txt <- readAllLines err_reader
          -- Interrupt process; suppress any exceptions that occur.
          catch (interruptProcessGroupOf ph) (\(_ :: IOError) -> return ())
          -- Wait for process to end
          ec <- waitForProcess ph
          let ec_code = case ec of
                          ExitSuccess -> 0
                          ExitFailure code -> code
          fail $ unlines
                  [ "The solver terminated with exit code "++
                                              show ec_code ++ ".\n"
                  , "*** exception: " ++ displayException e
                  , "*** standard error:"
                  , LazyText.unpack txt
                  ]
