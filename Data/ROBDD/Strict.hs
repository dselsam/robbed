module Data.ROBDD.Strict ( BDD(..)
                         , mk
                         , apply
                         , restrict
                         , makeVar
                         , makeTrue
                         , makeFalse
                         , viewDAG
                         , makeDAG
                         , and
                         , or
                         , xor
                         , impl
                         , biimpl
                         , nand
                         , nor
                         , neg
                         ) where

import Prelude hiding (and, or, negate)
import Control.Monad.State
import Data.HamtMap (HamtMap)
import qualified Data.HamtMap as M
import Data.Hashable

import qualified Data.Graph.Inductive as G
import Data.GraphViz

type Map = HamtMap

type RevMap = Map (Var, NodeId, NodeId) BDD

type NodeId = Int
type Var = Int

-- Node types
data BDD = BDD BDD Var BDD NodeId
         | Zero
         | One

makeTrue :: ROBDD
makeTrue = ROBDD M.empty [] One
makeFalse :: ROBDD
makeFalse = ROBDD M.empty [] Zero
makeVar :: Var -> ROBDD
makeVar v = ROBDD M.empty [] bdd
  where bdd = BDD Zero v One 2

-- Accessible wrapper
data ROBDD = ROBDD RevMap [Int] BDD

instance Eq BDD where
  Zero == Zero = True
  One == One = True
  (BDD _ _ _ id1) == (BDD _ _ _ id2) = id1 == id2
  _ == _ = False

instance Labellable BDD where
  toLabel Zero = toLabel "Zero"
  toLabel One = toLabel "One"
  toLabel (BDD _ v _ _) = toLabel $ show v


-- This is not an Ord instance because the EQ it returns is not the same
-- as the Eq typeclass - it is variable based instead of identity based
bddCmp :: BDD -> BDD -> Ordering
Zero `bddCmp` Zero = EQ
One `bddCmp` One = EQ
Zero `bddCmp` One = GT
One `bddCmp` Zero = LT
(BDD _ _ _ _) `bddCmp` Zero = LT
(BDD _ _ _ _) `bddCmp` One = LT
Zero `bddCmp` (BDD _ _ _ _) = GT
One `bddCmp` (BDD _ _ _ _) = GT
(BDD _ v1 _ _) `bddCmp` (BDD _ v2 _ _) = v1 `compare` v2

highEdge :: BDD -> BDD
highEdge (BDD _ _ h _) = h
highEdge _ = error "No high edge in Zero or One"

lowEdge :: BDD -> BDD
lowEdge (BDD l _ _ _) = l
lowEdge _ = error "No low edge in Zero or One"

nodeVar :: BDD -> Var
nodeVar (BDD _ v _ _) = v
nodeVar _ = error "No variable for Zero or One"

nodeUID :: BDD -> Int
nodeUID Zero = 0
nodeUID One = 1
nodeUID (BDD _ _ _ uid) = uid

data BDDState a = BDDState { bddRevMap :: RevMap
                           , bddIdSource :: [Int]
                           , bddMemoTable :: Map a BDD
                           }
type BDDContext a b = State (BDDState a) b

revLookup :: Var -> BDD -> BDD -> RevMap -> (Maybe BDD)
revLookup v leftTarget rightTarget revMap = do
  M.lookup (v, nodeUID leftTarget, nodeUID rightTarget) revMap

-- Create a new node for v with the given high and low edges.
-- Insert it into the revMap and return it.
revInsert :: Var -> BDD -> BDD -> BDDContext a BDD
revInsert v lowTarget highTarget = do
  s <- get
  let revMap = bddRevMap s
      (nodeId:rest) = bddIdSource s
      revMap' = M.insert (v, nodeUID lowTarget, nodeUID highTarget) newNode revMap
      newNode = BDD lowTarget v highTarget nodeId
  put $ s { bddRevMap = revMap'
          , bddIdSource = rest }

  return newNode

-- Start IDs at 2, since Zero and One are conceptually taken
emptyBDDState :: (Eq a, Hashable a) => BDDState a
emptyBDDState = BDDState { bddRevMap = M.empty
                         , bddIdSource = [2..]
                         , bddMemoTable = M.empty
                         }

-- | The MK operation.  Re-use an existing BDD node if possible.
-- Otherwise create a new node with the provided NodeId, updating the
-- tables.
mk :: Var -> BDD -> BDD -> BDDContext a BDD
mk v low high = do
  s <- get

  let revMap = bddRevMap s

  if low == high
    then return low -- Inputs identical, re-use
    else case revLookup v low high revMap of
      -- Return existing node
      Just node -> return node
      -- Make a new node
      Nothing -> revInsert v low high

-- A helper to memoize BDD nodes
memoNode :: (Eq a, Hashable a) => a -> BDD -> BDDContext a ()
memoNode key val = do
  s <- get
  let memoTable = bddMemoTable s
      memoTable' = M.insert key val memoTable

  put s { bddMemoTable = memoTable' }

getMemoNode :: (Eq a, Hashable a) => a -> BDDContext a (Maybe BDD)
getMemoNode key = do
  s <- get
  let memoTable = bddMemoTable s

  return $ M.lookup key memoTable

and :: ROBDD -> ROBDD -> ROBDD
and = apply (&&)
or :: ROBDD -> ROBDD -> ROBDD
or = apply (||)

boolXor :: Bool -> Bool -> Bool
True `boolXor` True = False
False `boolXor` False = False
_ `boolXor` _ = True

xor :: ROBDD -> ROBDD -> ROBDD
xor = apply boolXor

boolImpl :: Bool -> Bool -> Bool
True `boolImpl` True = True
True `boolImpl` False = False
False `boolImpl` True = True
False `boolImpl` False = True

impl :: ROBDD -> ROBDD -> ROBDD
impl = apply boolImpl

boolBiimp :: Bool -> Bool -> Bool
True `boolBiimp` True = True
False `boolBiimp` False = True
_ `boolBiimp` _ = False

biimpl :: ROBDD -> ROBDD -> ROBDD
biimpl = apply boolBiimp

boolNotAnd :: Bool -> Bool -> Bool
True `boolNotAnd` True = False
_ `boolNotAnd` _ = True

nand :: ROBDD -> ROBDD -> ROBDD
nand = apply boolNotAnd

boolNotOr :: Bool -> Bool -> Bool
False `boolNotOr` False = True
_ `boolNotOr` _ = False

nor :: ROBDD -> ROBDD -> ROBDD
nor = apply boolNotOr


-- | Construct a new BDD by applying the provided binary operator
-- to the two input BDDs
--
-- Note: the reverse node maps of each input BDD are ignored because
-- we need to build a new one on the fly for the result BDD.
apply :: (Bool -> Bool -> Bool) -> ROBDD -> ROBDD -> ROBDD
apply op (ROBDD _ _ bdd1) (ROBDD _ _ bdd2) =
  let (bdd, s) = runState (appCachedOrBase bdd1 bdd2) emptyBDDState
      -- FIXME: Remove unused bindings in the revmap to allow the
      -- runtime to GC unused nodes
  in ROBDD (bddRevMap s) (bddIdSource s) bdd
  where appCachedOrBase :: BDD -> BDD -> BDDContext (NodeId, NodeId) BDD
        appCachedOrBase lhs rhs = do
          memNode <- getMemoNode (nodeUID lhs, nodeUID rhs)

          case memNode of
            Just cachedVal -> return cachedVal
            Nothing -> case maybeApply lhs rhs of
              Just True -> return One
              Just False -> return Zero
              Nothing -> appRec lhs rhs

        appRec :: BDD -> BDD -> BDDContext (NodeId, NodeId) BDD
        appRec lhs rhs = do
          newNode <- case lhs `bddCmp` rhs of
                  -- Vars are the same
                  EQ -> do
                    newLowNode <- appCachedOrBase (lowEdge lhs) (lowEdge rhs)
                    newHighNode <- appCachedOrBase (highEdge lhs) (highEdge rhs)
                    mk (nodeVar lhs) newLowNode newHighNode
                  -- Var1 is less than var2
                  LT -> do
                    newLowNode <- appCachedOrBase (lowEdge lhs) rhs
                    newHighNode <- appCachedOrBase (highEdge lhs) rhs
                    mk (nodeVar lhs) newLowNode newHighNode
                  -- Var1 is greater than v2
                  GT -> do
                    newLowNode <- appCachedOrBase lhs (lowEdge rhs)
                    newHighNode <- appCachedOrBase lhs (highEdge rhs)
                    mk (nodeVar rhs) newLowNode newHighNode
          memoNode (nodeUID lhs, nodeUID rhs) newNode
          return newNode

        maybeApply :: BDD -> BDD -> Maybe Bool
        maybeApply lhs rhs = do
          b1 <- toBool lhs
          b2 <- toBool rhs
          return $ b1 `op` b2

        toBool :: BDD -> Maybe Bool
        toBool One = Just True
        toBool Zero = Just False
        toBool _ = Nothing

restrict :: ROBDD -> Var -> Bool -> ROBDD
restrict bdd@(ROBDD _ _ Zero) _ _ = bdd
restrict bdd@(ROBDD _ _ One) _ _ = bdd
restrict (ROBDD revMap idSrc bdd) v b =
  let (r,s) = runState (restrict' bdd) emptyBDDState { bddIdSource = idSrc
                                                     , bddRevMap = revMap
                                                     }
  in ROBDD (bddRevMap s) (bddIdSource s) r
  where restrict' Zero = return Zero
        restrict' One = return One
        restrict' o@(BDD low var high uid) = do
          mem <- getMemoNode uid
          case mem of
            Just node -> return node
            Nothing -> case var `compare` v of
              GT -> return o
              LT -> do
                low' <- restrict' low
                high' <- restrict' high
                n <- mk var low' high'
                memoNode uid n
                return n
              EQ -> case b of
                True -> restrict' high
                False -> restrict' low

-- TODO: Implement restrictAll :: ROBDD -> [(Var, Bool)] -> ROBDD
-- A fold would work, but it could be much more efficient to handle
-- them all at once

-- | Negate the given BDD.  This implementation is somewhat more
-- efficient than the naiive translation to BDD -> False.
-- Unfortunately, it isn't as much of an improvement as it could be
-- via destructive updates.
neg :: ROBDD -> ROBDD
neg (ROBDD _ _ bdd) =
  -- Everything gets re-allocated so don't bother trying to re-use the
  -- revmap or idsource
  let (r, s) = runState (negate' bdd) emptyBDDState
  in ROBDD (bddRevMap s) (bddIdSource s) r
  where negate' Zero = return One
        negate' One = return Zero
        negate' o@(BDD low var high uid) = do
          mem <- getMemoNode uid
          case mem of
            Just node -> return node
            Nothing -> do
              low' <- negate' low
              high' <- negate' high
              n <- mk var low' high'
              memoNode uid n
              return n

anySat :: ROBDD -> Maybe ([(Var, Bool)])
anySat (ROBDD _ _ Zero) = Nothing
anySat (ROBDD _ _ One) = Just []

type DAG = G.Gr BDD Bool

bddVarNum :: BDD -> Var
bddVarNum Zero = 0
bddVarNum One = 1
bddVarNum (BDD _ v _ _) = v

makeDAG :: ROBDD -> DAG
makeDAG (ROBDD _ _ bdd) = G.mkGraph nodeList (map unTuple $ M.toList edges)
  where nodes :: Map Var BDD
        nodes = collectNodes bdd M.empty
        nodeList :: [ (Var, BDD) ]
        nodeList = M.toList nodes
        collectNodes :: BDD -> Map Var BDD -> Map Var BDD
        collectNodes b@(BDD low v high _) s =
          let s' = collectNodes low s
              s'' = collectNodes high s'
          in M.insert v b s''
        collectNodes Zero s = M.insert 0 Zero s
        collectNodes One s = M.insert 1 One s
        edges :: Map (Var, Var) Bool
        edges = collectEdges bdd M.empty
        collectEdges :: BDD -> Map (Var, Var) Bool -> Map (Var, Var) Bool
        collectEdges (BDD low v high _) s =
          let s' = collectEdges low s
              s'' = collectEdges high s'
              s''' = M.insert (v, bddVarNum low) False s''
          in M.insert (v, bddVarNum high) True s'''
        collectEdges _ s = s
        unTuple ((a, b), c) = (a, b, c)

viewDAG dag = do
  let dg = graphToDot nonClusteredParams dag
  s <- prettyPrint dg
  putStrLn s
  preview dag

main = do
  let x2 = makeVar 2
      x3 = makeVar 3
      x4 = makeVar 4
      f1 = and x2 x3
      f2 = or f1 x4
      f3 = or f2 makeTrue -- tautology
      f4 = restrict f2 3 False
      f5 = negate f2
      dag = makeDAG f5

  viewDAG dag