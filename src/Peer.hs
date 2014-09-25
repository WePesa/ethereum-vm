{-# OPTIONS_GHC -Wall #-}

module Peer (
  Peer(..),
  peer2RLP,
  rlp2Peer
  ) where

import Data.ByteString.Internal
import Data.Word

import Format
import RLP

--import Debug.Trace



--instance Show Block where
--  show x = "<BLOCK>"



data IPAddr = IPAddr Word8 Word8 Word8 Word8 deriving (Show)

instance Format IPAddr where
  format (IPAddr v1 v2 v3 v4) = show v1 ++ "." ++ show v2 ++ "." ++ show v3 ++ "." ++ show v4 

data Peer = Peer {
  ipAddr::IPAddr,
  peerPort::Word16,
  uniqueId::String
  } deriving (Show)

instance Format Peer where
  format peer = format (ipAddr peer) ++ ":" ++ show (peerPort peer)


rlp2Peer::RLPObject->Peer
rlp2Peer (RLPArray [RLPString [c1, c2, c3, c4], RLPNumber p, RLPString uid]) =
  Peer {
    ipAddr = IPAddr (c2w c1) (c2w c2) (c2w c3) (c2w c4),
    peerPort = fromIntegral p,
    uniqueId = uid
    }
rlp2Peer x = error ("rlp2Peer called on non block object: " ++ show x)

peer2RLP::Peer->RLPObject
peer2RLP peer = undefined
