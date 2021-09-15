{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DerivingStrategies    #-}
{-# LANGUAGE DerivingVia           #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MonoLocalBinds        #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE ViewPatterns          #-}

module Plutus.ChainIndex.TxIdState(
    isConfirmed
    , increaseDepth
    , initialStatus
    , transactionStatus
    , fromTx
    , fromBlock
    , rollback
    , chainConstant
    ) where

import           Control.Lens                ((^.))
import           Data.FingerTree             (Measured (..), (|>))
import qualified Data.FingerTree             as FT
import qualified Data.Map                    as Map
import           Data.Monoid                 (Last (..), Sum (..))
import           Ledger                      (OnChainTx, TxId, eitherTx)
import           Plutus.ChainIndex.Tx        (ChainIndexTx (..), ChainIndexTxOutputs (..), citxOutputs, citxTxId)
import           Plutus.ChainIndex.Types     (BlockNumber (..), Depth (..), Point (..), Tip (..), TxConfirmedState (..),
                                              TxIdState (..), TxStatus (..), TxStatusFailure (..), TxValidity (..),
                                              pointsToTip)
import           Plutus.ChainIndex.UtxoState (RollbackFailed (..), RollbackResult (..), UtxoIndex, UtxoState (..), tip,
                                              viewTip)


-- | The 'TxStatus' of a transaction right after it was added to the chain
initialStatus :: OnChainTx -> TxStatus
initialStatus =
  TentativelyConfirmed 0 . eitherTx (const TxInvalid) (const TxValid)

-- | Whether a 'TxStatus' counts as confirmed given the minimum depth
isConfirmed :: Depth -> TxStatus -> Bool
isConfirmed minDepth = \case
    TentativelyConfirmed d _ | d >= minDepth -> True
    Committed{}                              -> True
    _                                        -> False

-- | Increase the depth of a tentatively confirmed transaction
increaseDepth :: TxStatus -> TxStatus
increaseDepth (TentativelyConfirmed d s)
  | d < succ chainConstant = TentativelyConfirmed (d + 1) s
  | otherwise              = Committed s
increaseDepth e            = e

-- TODO: Configurable!
-- | The depth (in blocks) after which a transaction cannot be rolled back anymore
chainConstant :: Depth
chainConstant = Depth 8

-- | Given the current block, compute the status for the given transaction by
-- checking to see if it has been deleted.
transactionStatus :: BlockNumber -> TxIdState -> TxId -> Either TxStatusFailure TxStatus
transactionStatus currentBlock txIdState txId
  = case (confirmed, deleted) of
       (Nothing, _)      -> Right Unknown

       (Just TxConfirmedState{blockAdded=Last (Just block'), validity=Last (Just validity')}, Nothing) ->
         if block' + (fromIntegral chainConstant) >= currentBlock
            then Right $ newStatus block' validity'
            else Right $ Committed validity'

       (Just TxConfirmedState{timesConfirmed=confirms, blockAdded=Last (Just block'), validity=Last (Just validity')}, Just deletes) ->
         if confirms >= deletes
            then Right $ newStatus block' validity'
            else Right $ Unknown

       _ -> Left $ TxIdStateInvalid currentBlock txId txIdState
    where
      newStatus block' validity' = TentativelyConfirmed (Depth $ fromIntegral $ currentBlock - block') validity'
      confirmed = Map.lookup txId (txnsConfirmed txIdState)
      deleted   = Map.lookup txId (txnsDeleted txIdState)


fromBlock :: Tip -> [ChainIndexTx] -> UtxoState TxIdState
fromBlock tip_ transactions =
  UtxoState
    { _usTxUtxoData = foldMap (fromTx $ tipBlockNo tip_) transactions
    , _usTip = tip_
    }

validityFromChainIndex :: ChainIndexTx -> TxValidity
validityFromChainIndex tx =
  case tx ^. citxOutputs of
    InvalidTx -> TxInvalid
    ValidTx _ -> TxValid

fromTx :: BlockNumber -> ChainIndexTx -> TxIdState
fromTx blockAdded tx =
  TxIdState
    { txnsConfirmed =
        Map.singleton
          (tx ^. citxTxId)
          (TxConfirmedState { timesConfirmed = Sum 1
                            , blockAdded = Last (Just blockAdded)
                            , validity = Last . Just $ validityFromChainIndex tx })
    , txnsDeleted = mempty
    }

rollback :: Point
         -> UtxoIndex TxIdState
         -> Either RollbackFailed (RollbackResult TxIdState)
rollback _             (viewTip -> TipAtGenesis) = Left RollbackNoTip
rollback targetPoint idx@(viewTip -> currentTip)
    -- The rollback happened sometime after the current tip.
    | not (targetPoint `pointLessThanTip` currentTip) =
        Left TipMismatch{foundTip=currentTip, targetPoint}
    | otherwise = do
        let (before, deleted) = FT.split (pointLessThanTip targetPoint . tip) idx

        case tip (measure before) of
            TipAtGenesis -> Left $ OldPointNotFound targetPoint
            oldTip | targetPoint `pointsToTip` oldTip ->
                      let x = _usTxUtxoData (measure deleted)
                          newTxIdState = TxIdState
                                            { txnsConfirmed = mempty
                                            , txnsDeleted = const 1 <$> txnsConfirmed x
                                            }
                          newUtxoState = UtxoState newTxIdState oldTip
                       in Right RollbackResult{newTip=oldTip, rolledBackIndex=before |> newUtxoState }
                   | otherwise -> Left  TipMismatch{foundTip=oldTip, targetPoint}
    where
      pointLessThanTip :: Point -> Tip -> Bool
      pointLessThanTip PointAtGenesis  _               = True
      pointLessThanTip (Point pSlot _) (Tip tSlot _ _) = pSlot < tSlot
      pointLessThanTip _               TipAtGenesis    = False