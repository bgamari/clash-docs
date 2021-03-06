{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NoMonomorphismRestriction  #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE TemplateHaskell            #-}
module Overdrive
  ( circuit
  , testBench
  , main
  ) where

-- clash and base imports
import           Prelude                hiding (undefined)

import           Clash.Prelude          hiding (length, reverse, take, zip)
import           Clash.Prelude.Moore    (moore)

-- monads
import           Data.Functor.Identity  (Identity, runIdentity)
import           Control.Monad.State
import           Control.Monad.Reader

-- lens
import           Control.Lens           (use, view)
import           Control.Lens.Operators ((.=))
import           Control.Lens.TH        (makeFieldsNoPrefix)

-- testing
import           Hedgehog
import           Hedgehog.Gen           as HH.Gen
import           Hedgehog.Range         as HH.Range

import           Test.Tasty             (defaultMain, testGroup)
import           Test.Tasty.Hedgehog    (testProperty)
import           Test.Tasty.HUnit       (testCase, assertBool)

--------------------------------------------------------------------------------

-- reader environment: the incoming parameters to the MAC and the accumulator
-- value
data In a = In { _x :: a, _y :: a }
  deriving (Eq, Show, Ord, Bounded)

-- state environment: the current accumulator value. by using 'newtype' we can
-- derive a 'Num' and 'BitPack' instance automatically via
-- GeneralizedNewtypeDeriving. this lets us convert between equally sized types,
-- and have literals like '0 :: Acc (Unsigned 23)'
newtype Acc a = Acc { _acc :: a }
  deriving (Eq, Show, Ord, Bounded, Num, BitPack)

-- monadic representation of a combinational MAC circuit state function. use GND
-- to derive instances automatically
newtype M a r = M { _unM :: ReaderT (In a) (StateT (Acc a) Identity) r }
  deriving ( Functor, Applicative, Monad
           , MonadReader (In a)
           , MonadState  (Acc a)
           )

-- generate fancy lenses
makeFieldsNoPrefix ''In
makeFieldsNoPrefix ''Acc

-- run a monadic representation of a combinational MAC state function
runM :: Num a => In a -> Acc a -> M a r -> Acc a
runM inp initial act
  = runIdentity             -- unwrap identity
  $ flip execStateT initial -- unwrap state
  $ flip runReaderT inp     -- unwrap reader
  $ _unM act                -- unwrap action

-- translate an 'M' monadic action into a type that is closer to a moore
-- transfer function. this is isomorphic to `runM`, as it simply moves some of
-- the parameters around.
mToTransfer :: Num a
            => M a r                    -- input: monadic action
            -> (Acc a -> In a -> Acc a) -- output: transfer function
mToTransfer act st inp = runM inp st act

--------------------------------------------------------------------------------

-- A highly generalized MAC function, parameterized over the fields used by the
-- underlying state and reader monad instances, generated by the lens package
--
-- NOTE: GHC and Clash can *fully* infer the type of "mac" with no help!
mac' :: forall env st m a.
        ( Num a
        , MonadReader env m, HasX env a, HasY env a
        , MonadState st m, HasAcc st a
        ) => m ()
mac' = do
  in1 <- view x                 -- get the input parameters
  in2 <- view y

  result <- use acc             -- get current accumulator
  acc .= (result + (in1 * in2)) -- calculate MAC, update state all at once

  return ()                     -- return nothing

-- specialize the mac function to our chosen monad
mac :: Num a => M a ()
mac = mac'

-- top level, synthesizable circuit
circuit :: SystemClockReset
        => Signal System (Signed 9)
        -> Signal System (Signed 9)
        -> Signal System (Signed 9)
circuit in1 in2
  = fmap bitCoerce               -- convert 'Acc (Signed 9) -> Signed 9'
  $ moore (mToTransfer mac) id 0 -- apply moore machine to input
  $ fmap (uncurry In)            -- convert (x,y) signal to 'In' signal
  $ bundle (in1, in2)            -- bundle two signals into one

{-# ANN circuit
  (defTop
    { t_name   = "mac"
    , t_inputs = [ PortName "clk"
                 , PortName "rst"
                 , PortName "in1"
                 , PortName "in2"
                 ]
    , t_output = PortName "out"
    }) #-}

-- simulated version of the input circuit. the definition is slightly
-- contorted because 'simulate' (normally) only takes a single input signal,
-- but we need two
circuit_simulated :: [Signed 9] -> [Signed 9] -> [Signed 9]
circuit_simulated xs ys = go (zip xs ys)
  where go = simulate_lazy $ \ins ->
          let (in1, in2) = unbundle ins
          in  circuit in1 in2

-- an ideal model of the circuit's behavior, one that's elegant and beautiful,
-- not a horrifying monstrosity
circuit_model :: [Signed 9] -> [Signed 9] -> [Signed 9]
circuit_model x y = Prelude.scanl (\a (x', y') -> a + (x' * y')) 0 (zip x y)

--------------------------------------------------------------------------------

-- a test bench that can be synthesized
testBench :: Signal System Bool
testBench = done
  where
    -- two input vectors, fed every clock cycle
    in1 = 1 :> 2 :> 3 :> 4 :> Nil
    in2 = 1 :> 2 :> 3 :> 4 :> Nil

    -- the expected result of the circuit for every clock cycle
    out = 0 :> 1 :> 5 :> 14 :> Nil

    -- use clash-prelude to create "test generator signals" out of the inputs
    -- and outputs
    genInput1   = stimuliGenerator in1
    genInput2   = stimuliGenerator in2
    checkOutput = outputVerifier out

    -- generate the resulting signal to check, and tie it together
    -- with a clock line.
    result = checkOutput (circuit genInput1 genInput2)
    done   = withClockReset (tbSystemClock (not <$> done)) systemReset result

-- a hedgehog property, stating that the simulated MAC circuit is the same
-- as the original version
prop_model_equiv :: Int -> Property
prop_model_equiv cycles = property $ do
  -- generate random individual 'Signed 9' values in the appropriate range
  let sr = HH.Range.constantFrom 0 minBound maxBound

  -- generate synthetic input signals, that effectively model the number of
  -- simulated cycles to test for
  let lr = HH.Range.linear 0 cycles

  -- generate two lists representing input signals. the length of this list
  -- effectively determines how many input cycles to sample, meaning that
  -- property shrinking will cause hedgehog to find the "earliest invalid cycle"
  -- that the property is violated.
  xs <- forAll $ HH.Gen.list lr (HH.Gen.integral sr)
  ys <- forAll $ HH.Gen.list lr (HH.Gen.integral sr)

  -- establish the real circuit is equal to the spec, up-to the specified
  -- number of cycles
  let trim = take (min (length xs) (length ys))
  trim (circuit_model xs ys) === trim (circuit_simulated xs ys)

--------------------------------------------------------------------------------

-- top level driver for the simulation tests and properties
main :: IO ()
main = defaultMain $ testGroup "Multiply-And-Accumulate"
  [ testGroup "Unit Tests"
      [ testCase "Synthsized testBench" $
          assertBool "" $ Prelude.all (== False) (sampleN 4 testBench)
      ]
  , testGroup "Properties"
      [ testProperty "circuit == spec (100 cycles)" (prop_model_equiv 100)
      , testProperty "circuit == spec (1000 cycles)" (prop_model_equiv 1000)
      ]
  ]
