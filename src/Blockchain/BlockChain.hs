{-# LANGUAGE OverloadedStrings, FlexibleContexts #-}

module Blockchain.BlockChain (
  nextDifficulty,
  addBlock,
  addBlocks,
  getBestBlock,
  getBestBlockHash,
  getGenesisBlockHash
  ) where

import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.State
import Data.Binary hiding (get)
import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Functor
import Data.Maybe
import Data.Time
import Data.Time.Clock.POSIX
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import Blockchain.Context
import Blockchain.Data.Address
import Blockchain.Data.AddressState
import Blockchain.Data.Block
import Blockchain.Data.RLP
import Blockchain.Data.SignedTransaction
import Blockchain.Data.Transaction
import Blockchain.DB.CodeDB
import Blockchain.Database.MerklePatricia
import Blockchain.DB.ModifyStateDB
import qualified Blockchain.Colors as CL
import Blockchain.Constants
import Blockchain.ExtDBs
import Blockchain.Format
import Blockchain.Data.GenesisBlock
import Blockchain.SHA
import Blockchain.Util
import Blockchain.VM
import Blockchain.VM.Code
import Blockchain.VM.Environment
import Blockchain.VM.VMState

--import Debug.Trace

{-
initializeBlockChain::ContextM ()
initializeBlockChain = do
  let bytes = rlpSerialize $ rlpEncode genesisBlock
  blockDBPut (BL.toStrict $ encode $ blockHash $ genesisBlock) bytes
  detailsDBPut "best" (BL.toStrict $ encode $ blockHash genesisBlock)
-}

nextDifficulty::Integer->UTCTime->UTCTime->Integer
nextDifficulty oldDifficulty oldTime newTime =
    if round (utcTimeToPOSIXSeconds newTime) >=
           (round (utcTimeToPOSIXSeconds oldTime) + 5::Integer)
    then oldDifficulty - oldDifficulty `shiftR` 10
    else oldDifficulty + oldDifficulty `shiftR` 10

nextGasLimit::Integer->Integer->Integer
nextGasLimit oldGasLimit oldGasUsed = max 125000 ((oldGasLimit * 1023 + oldGasUsed *6 `quot` 5) `quot` 1024)

checkUnclesHash::Block->Bool
checkUnclesHash b = unclesHash (blockData b) == hash (rlpSerialize $ RLPArray (rlpEncode <$> blockUncles b))

--data BlockValidityError = BlockDifficultyWrong Integer Integer | BlockNumberWrong Integer Integer | BlockGasLimitWrong Integer Integer | BlockNonceWrong | BlockUnclesHashWrong
{-
instance Format BlockValidityError where
    --format BlockOK = "Block is valid"
    format (BlockDifficultyWrong d expected) = "Block difficulty is wrong, is '" ++ show d ++ "', expected '" ++ show expected ++ "'"
-}

verifyStateRootExists::Block->ContextM Bool
verifyStateRootExists b = do
  val <- stateDBGet (BL.toStrict $ encode $ bStateRoot $ blockData b)
  case val of
    Nothing -> return False
    Just _ -> return True

checkParentChildValidity::(Monad m)=>Block->Block->m ()
checkParentChildValidity Block{blockData=c} Block{blockData=p} = do
    unless (difficulty c == nextDifficulty (difficulty p) (timestamp p) ( timestamp c))
             $ fail $ "Block difficulty is wrong: got '" ++ show (difficulty c) ++ "', expected '" ++ show (nextDifficulty (difficulty p) (timestamp p) ( timestamp c)) ++ "'"
    unless (number c == number p + 1) 
             $ fail $ "Block number is wrong: got '" ++ show (number c) ++ ", expected '" ++ show (number p + 1) ++ "'"
    unless (gasLimit c == nextGasLimit (gasLimit p) (gasUsed p))
             $ fail $ "Block gasLimit is wrong: got '" ++ show (gasLimit c) ++ "', expected '" ++ show (nextGasLimit (gasLimit p) (gasUsed p)) ++ "'"
    return ()

checkValidity::Monad m=>Block->ContextM (m ())
checkValidity b = do
  maybeParentBlock <- getBlock (parentHash $ blockData b)
  case maybeParentBlock of
    Just parentBlock -> do
          checkParentChildValidity b parentBlock
          unless (nonceIsValid b) $ fail $ "Block nonce is wrong: " ++ format b
          unless (checkUnclesHash b) $ fail "Block unclesHash is wrong"
          stateRootExists <- verifyStateRootExists b
          unless stateRootExists $ fail ("Block stateRoot does not exist: " ++ show (pretty $ bStateRoot $ blockData b))
          return $ return ()
    Nothing -> fail ("Parent Block does not exist: " ++ show (pretty $ parentHash $ blockData b))


{-
                    coinbase=prvKey2Address prvKey,
        stateRoot = SHA 0x9b109189563315bfeb13d4bfd841b129ff3fd5c85f228a8d9d8563b4dde8432e,
                    transactionsTrie = 0,
-}


runCodeForTransaction::Block->Integer->SignedTransaction->ContextM ()
runCodeForTransaction b availableGas t@SignedTransaction{unsignedTransaction=ut@ContractCreationTX{}} = do
  liftIO $ putStrLn "runCodeForTransaction: ContractCreationTX"
  let tAddr = whoSignedThisTransaction t

  liftIO $ putStrLn $ "availableGas: " ++ show availableGas

  let newAddress = getNewAddress tAddr $ tNonce $ unsignedTransaction t

  liftIO $ putStrLn $ "running code: " ++ tab (CL.magenta ("\n" ++ show (pretty $ tInit ut)))

  pay tAddr (coinbase $ blockData b) (availableGas*gasPrice ut)

  (vmState, newStorageStateRoot) <- 
    runCodeFromStart tAddr 0 availableGas
          Environment{
            envGasPrice=gasPrice ut,
            envBlock=b,
            envOwner = newAddress,
            envOrigin = tAddr,
            envInputData = B.empty, --error "envInputData is being used in init",
            envSender = tAddr,
            envValue = value ut,
            envCode = tInit ut
            }

  liftIO $ putStrLn "VM has finished running"

  liftIO $ putStrLn $ "gasRemaining: " ++ show (vmGasRemaining vmState)
  let usedGas =  - vmGasRemaining vmState - refund vmState
  liftIO $ putStrLn $ "gasUsed: " ++ show usedGas
  pay tAddr (coinbase $ blockData b) (usedGas * gasPrice ut)

  case vmException vmState of
        Just e -> do
          liftIO $ putStrLn $ CL.red $ show e
          putAddressState newAddress
                   AddressState{
                     addressStateNonce=0,
                     balance=0,
                     contractRoot=emptyTriePtr,
                     codeHash=hash B.empty
                   }

          pay tAddr newAddress (value ut)
        Nothing -> do
          let result = fromMaybe B.empty $ returnVal vmState
          liftIO $ putStrLn $ "Result: " ++ show result
          pay tAddr (coinbase $ blockData b) (5*toInteger (B.length result)*gasPrice ut)
          liftIO $ putStrLn $ show (pretty newAddress) ++ ": " ++ format result
          --cxt <- get
          liftIO $ putStrLn $ "adding storage " ++ show (pretty newStorageStateRoot) -- stateRoot $ storageDB cxt)
          addCode result
          putAddressState newAddress
                   AddressState{
                     addressStateNonce=0,
                     balance=0,
                     contractRoot=newStorageStateRoot,
                     codeHash=hash result
                   }

          liftIO $ putStrLn $ "paying: " ++ show (value ut)
          pay tAddr newAddress (value ut)

runCodeForTransaction b availableGas t@SignedTransaction{unsignedTransaction=ut@MessageTX{}} = do
  liftIO $ putStrLn "runCodeForTransaction: MessageTX"
  recipientAddressState <- getAddressState (to ut)

  liftIO $ putStrLn $ "Looking for contract code for: " ++ show (pretty $ to ut)
  --liftIO $ putStrLn $ "codeHash is: " ++ show (pretty $ sha2SHAPtr $ codeHash recipientAddressState)

  contractCode <- 
      fromMaybe B.empty <$>
                getCode (codeHash recipientAddressState)

  liftIO $ putStrLn $ "running code: " ++ tab (CL.magenta ("\n" ++ show (pretty (Code contractCode))))

  let tAddr = whoSignedThisTransaction t

  liftIO $ putStrLn $ "availableGas: " ++ show availableGas

  pay tAddr (coinbase $ blockData b) (availableGas*gasPrice ut)

  pay (whoSignedThisTransaction t) (to ut) (value ut)

  (vmState, newStorageStateRoot) <- 
          runCodeFromStart (to ut) 0 availableGas
                 Environment{
                           envGasPrice=gasPrice ut,
                           envBlock=b,
                           envOwner = to ut,
                           envOrigin = tAddr,
                           envInputData = tData ut,
                           envSender = tAddr,
                           envValue = value ut,
                           envCode = Code contractCode
                         }

  liftIO $ putStrLn $ "newStorageStateRoot: " ++ show (pretty newStorageStateRoot)

  liftIO $ putStrLn $ "gasRemaining: " ++ show (vmGasRemaining vmState)
  let usedGas = - vmGasRemaining vmState - refund vmState
  liftIO $ putStrLn $ "gasUsed: " ++ show usedGas
  pay tAddr (coinbase $ blockData b) (usedGas * gasPrice ut)

  case vmException vmState of
        Just e -> do
          liftIO $ putStrLn $ CL.red $ show e
          --addToBalance tAddr (-value ut) --zombie account, money lost forever
          {-addressState <- getAddressState (to ut)
          cxt <- get
          putAddressState (to ut)
                 addressState{contractRoot=stateRoot $ storageDB cxt}-}
        Nothing -> do
          addressState <- getAddressState (to ut)
          putAddressState (to ut) addressState{contractRoot=newStorageStateRoot}
          return ()





addBlocks::[Block]->ContextM ()
addBlocks blocks = 
  forM_ blocks addBlock

isTransactionValid::SignedTransaction->ContextM Bool
isTransactionValid t = do
  addressState <- getAddressState $ whoSignedThisTransaction t
  return (addressStateNonce addressState == tNonce (unsignedTransaction t))

intrinsicGas::Transaction->Integer
intrinsicGas t = zeroLen + 5 * (fromIntegral (codeOrDataLength t) - zeroLen) + 500
    where
      zeroLen = fromIntegral $ zeroBytesLength t
--intrinsicGas t@ContractCreationTX{} = 5 * (fromIntegral (codeOrDataLength t)) + 500

addTransaction::Block->SignedTransaction->ContextM ()
addTransaction b t@SignedTransaction{unsignedTransaction=ut} = do
  liftIO $ putStrLn "adding to nonces"
  let signAddress = whoSignedThisTransaction t
  addNonce signAddress
  liftIO $ putStrLn "paying value to recipient"

  let intrinsicGas' = intrinsicGas ut
  liftIO $ putStrLn $ "intrinsicGas: " ++ show (intrinsicGas')
  --TODO- return here if not enough gas
  --liftIO $ putStrLn $ "Paying " ++ show (intrinsicGas' * gasPrice ut) ++ " from " ++ show (pretty signAddress) ++ " to " ++ show (pretty $ coinbase $ blockData b)
  pay signAddress (coinbase $ blockData b) (intrinsicGas' * gasPrice ut)

  liftIO $ putStrLn "running code"
  runCodeForTransaction b (tGasLimit ut - intrinsicGas') t

addTransactions::Block->[SignedTransaction]->ContextM ()
addTransactions _ [] = return ()
addTransactions b (t:rest) = do
  valid <- isTransactionValid t
  liftIO $ putStrLn $ "Coinbase: " ++ show (pretty $ coinbase $ blockData b)
  liftIO $ putStrLn $ "Transaction signed by: " ++ show (pretty $ whoSignedThisTransaction t)
  addressState <- getAddressState $ whoSignedThisTransaction t
  liftIO $ putStrLn $ "User balance: " ++ show (balance $ addressState)
  liftIO $ putStrLn $ "Transaction is valid: " ++ show valid
  when valid $ addTransaction b t
  addTransactions b rest
  
addBlock::Block->ContextM ()
addBlock b@Block{blockData=bd, blockUncles=uncles} = do
  liftIO $ putStrLn $ "Attempting to insert block #" ++ show (number bd) ++ " (" ++ show (pretty $ blockHash b) ++ ")."
  maybeParent <- getBlock $ parentHash bd
  case maybeParent of
    Nothing ->
      liftIO $ putStrLn $ "Missing parent block in addBlock: " ++ show (pretty $ parentHash bd) ++ "\n" ++
      "Block will not be added now, but will be requested and added later"
    Just parentBlock -> do
      setStateRoot $ bStateRoot $ blockData parentBlock
      let rewardBase = 1500 * finney
      addToBalance (coinbase bd) rewardBase

      forM_ uncles $ \uncle -> do
                          addToBalance (coinbase bd) (rewardBase `quot` 32)
                          addToBalance (coinbase uncle) (rewardBase*15 `quot` 16)

      let transactions = receiptTransactions b
      addTransactions b transactions

      ctx <- get
      liftIO $ putStrLn $ "newStateRoot: " ++ show (pretty $ stateRoot $ stateDB ctx)

      valid <- checkValidity b
      case valid of
        Right () -> return ()
        Left err -> error err
      let bytes = rlpSerialize $ rlpEncode b
      blockDBPut (BL.toStrict $ encode $ blockHash b) bytes
      replaceBestIfBetter b

getBestBlockHash::ContextM SHA
getBestBlockHash = do
  maybeBestHash <- detailsDBGet "best"
  case maybeBestHash of
    Nothing -> blockHash <$> initializeGenesisBlock
    Just bestHash -> return $ decode $ BL.fromStrict $ bestHash

getGenesisBlockHash::ContextM SHA
getGenesisBlockHash = do
  maybeGenesisHash <- detailsDBGet "genesis"
  case maybeGenesisHash of
    Nothing -> blockHash <$> initializeGenesisBlock
    Just bestHash -> return $ decode $ BL.fromStrict $ bestHash

getBestBlock::ContextM Block
getBestBlock = do
  bestBlockHash <- getBestBlockHash
  bestBlock <- getBlock bestBlockHash
  return $ fromMaybe (error $ "Missing block in database: " ++ show (pretty bestBlockHash)) bestBlock
      

replaceBestIfBetter::Block->ContextM ()
replaceBestIfBetter b = do
  best <- getBestBlock
  if number (blockData best) >= number (blockData b) 
       then return ()
       else detailsDBPut "best" (BL.toStrict $ encode $ blockHash b)
