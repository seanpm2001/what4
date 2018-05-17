{-|
Module      : Lang.Crucible.Backend
Copyright   : (c) Galois, Inc 2014-2016
License     : BSD3
Maintainer  : Joe Hendrix <jhendrix@galois.com>

This module provides an interface that symbolic backends must provide
for interacting with the symbolic simulator.
-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE TypeFamilies #-}
module Lang.Crucible.Backend
  ( BranchResult(..)
  , IsBoolSolver(..)
  , IsSymInterface

    -- * Assumption management
  , AssumptionReason(..)
  , assumptionLoc
  , Assertion
  , Assumption
  , ProofObligation
  , AssumptionState
  , assert

    -- ** Reexports
  , AS.LabeledPred(..)
  , AS.labeledPred
  , AS.labeledPredMsg
  , AS.ProofGoal(..)
  , AS.AssumptionStack
  , AS.FrameIdentifier

    -- * Utilities
  , addAssertionM
  , assertIsInteger
  , readPartExpr
  , abortExecSimErrorReason
  , abortExecSimError
  ) where

import           Data.Sequence (Seq)
import           Control.Exception(throwIO)

import           What4.Interface
import           What4.Partial
import           What4.ProgramLoc

import qualified Lang.Crucible.Backend.AssumptionStack as AS
import           Lang.Crucible.Simulator.SimError

data AssumptionReason =
    AssumptionReason ProgramLoc String
    -- ^ An unstructured description of the source of an assumption.

  | ExploringAPath ProgramLoc
    -- ^ This arose because we want to explore a specific path.

  | AssumingNoError SimError
    -- ^ An assumption justified by a proof of the impossibility of
    -- a certain simulator error.

assumptionLoc :: AssumptionReason -> ProgramLoc
assumptionLoc r =
  case r of
    AssumptionReason l _ -> l
    ExploringAPath l     -> l
    AssumingNoError s    -> simErrorLoc s

instance AS.AssumeAssert AssumptionReason SimError where
  assertToAssume = AssumingNoError


type Assertion sym  = AS.LabeledPred (Pred sym) SimError
type Assumption sym = AS.LabeledPred (Pred sym) AssumptionReason

type ProofObligation sym = AS.ProofGoal (Pred sym) AssumptionReason SimError
type AssumptionState sym = AS.AssumptionStack (Pred sym) AssumptionReason SimError




-- | Result of attempting to branch on a predicate.
data BranchResult
     -- | Branch is symbolic.
     --
     -- The Boolean value indicates whether the backend suggests that the active
     -- path should be the case where the condition is true or false.
   = SymbolicBranch !Bool

     -- | No branch is needed, and the predicate is evaluated to the
     -- given value.
   | NoBranch !Bool

type IsSymInterface sym = (IsBoolSolver sym, IsSymExprBuilder sym)

-- | This class provides operations that interact with the symbolic simulator.
--   It allows for logical assumptions/assertions to be added to the current
--   path condition, and allows queries to be asked about branch conditions.
class IsBoolSolver sym where

  ----------------------------------------------------------------------
  -- Branch manipulations

  -- | Given a Boolean predicate that the simulator wishes to branch on,
  --   this decides what the next course of action should be for the branch.
  evalBranch :: sym
             -> Pred sym -- Predicate to branch on.
             -> IO BranchResult

  -- | Push a new assumption frame onto the stack.  Assumptions and assertions
  --   made will now be associated with this frame on the stack until a new
  --   frame is pushed onto the stack, or until this one is popped.
  pushAssumptionFrame :: sym -> IO AS.FrameIdentifier

  -- | Pop an assumption frame from the stack.  The collected assumptions
  --   in this frame are returned.  Pops are required to be well-bracketed
  --   with pushes.  In particular, if the given frame identifier is not
  --   the identifier of the top frame on the stack, an error will be raised.
  popAssumptionFrame :: sym -> AS.FrameIdentifier -> IO (Seq (Assumption sym))

  ----------------------------------------------------------------------
  -- Assertions

  -- | Add an assertion to the current state.
  --
  -- This may throw the given @SimErrorReason@ if the assertion is unsatisfiable.
  --
  -- Every assertion added to the system produces a proof obligation. These
  -- proof obligations can be retrieved via the 'getProofObligations' call.
  addAssertion :: sym -> Assertion sym -> IO ()

  -- | Add an assumption to the current state.  Like assertions, assumptions
  --   add logical facts to the current path condition.  However, assumptions
  --   do not produce proof obligations the way assertions do.
  addAssumption :: sym -> Assumption sym -> IO ()

  -- | Add a collection of assumptions to the current state.
  addAssumptions :: sym -> Seq (Assumption sym) -> IO ()

  -- | This will cause the current path to fail, with the given error.
  addFailedAssertion :: sym -> SimErrorReason -> IO a

  -- | Get the current path condition as a predicate.  This consists of the conjunction
  --   of all the assumptions currently in scope.
  getPathCondition :: sym -> IO (Pred sym)

  -- | Get the collection of proof obligations.
  getProofObligations :: sym -> IO (Seq (ProofObligation sym))

  -- | Set the collection of proof obligations to the given sequence.  Typically, this is used
  --   to remove proof obligations that have been successfully proved by resetting the list
  --   of obligations to be only those not proved.
  setProofObligations :: sym -> Seq (ProofObligation sym) -> IO ()

  -- | Create a snapshot of the current assumption state, that may later be restored.
  --   This is useful for supporting control-flow patterns that don't neatly fit into
  --   the stack push/pop model.
  cloneAssumptionState :: sym -> IO (AssumptionState sym)

  -- | Restore the assumption state to a previous snapshot.
  restoreAssumptionState :: sym -> AssumptionState sym -> IO ()


-- | Throw an exception, thus aborting the current execution path.
abortExecSimError :: IsSymInterface sym => sym -> SimError -> IO a
abortExecSimError _sym err = throwIO err

-- | Throw an exception, thus aborting the current execution path.
abortExecSimErrorReason :: IsSymInterface sym => sym -> SimErrorReason -> IO a
abortExecSimErrorReason sym reason =
  do loc <- getCurrentProgramLoc sym
     throwIO SimError { simErrorLoc = loc, simErrorReason = reason }

assert ::
  IsSymInterface sym =>
  sym ->
  Pred sym ->
  SimErrorReason ->
  IO ()
assert sym p msg =
  do loc <- getCurrentProgramLoc sym
     addAssertion sym (AS.LabeledPred p (SimError loc msg))

-- | Run the given action to compute a predicate, and assert it.
addAssertionM :: IsSymInterface sym
              => sym
              -> IO (Pred sym)
              -> SimErrorReason
              -> IO ()
addAssertionM sym pf msg = do
  p <- pf
  assert sym p msg

-- | Assert that the given real-valued expression is an integer.
assertIsInteger :: IsSymInterface sym
                => sym
                -> SymReal sym
                -> SimErrorReason
                -> IO ()
assertIsInteger sym v msg = do
  addAssertionM sym (isInteger sym v) msg

-- | Given a partial expression, assert that it is defined
--   and return the underlying value.
readPartExpr :: IsSymInterface sym
             => sym
             -> PartExpr (Pred sym) v
             -> SimErrorReason
             -> IO v
readPartExpr sym Unassigned msg = do
  addFailedAssertion sym msg
readPartExpr sym (PE p v) msg = do
  loc <- getCurrentProgramLoc sym
  addAssertion sym (AS.LabeledPred p (SimError loc msg))
  return v