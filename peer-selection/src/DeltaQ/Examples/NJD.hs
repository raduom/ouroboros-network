module DeltaQ.Examples.NJD
where

import           Algebra.Graph.Labelled.AdjacencyMap
import           Data.List
import           Data.Map.Strict
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Time.Clock (DiffTime)
import           DeltaQ.Examples.AWS
import           DeltaQ.LinkRestriction
import           DeltaQ.SimpleGS
import           DeltaQ.TCP
import           DeltaQ.Topography
import           Numeric.Natural

testVertexSet :: Set NetNode
testVertexSet
  = Set.fromList [LondonAWS, IrelandAWS, FrankfurtAWS, TokyoAWS, NVirginiaAWS, SydneyAWS, SaoPauloAWS]
--  = Set.fromList [OhioAWS, SydneyAWS, SaoPauloAWS]
--  = Set.fromList [FrankfurtAWS, IrelandAWS, LondonAWS]

testTopography :: AdjacencyMap (Edges BearerCharacteristics) NetNode
testTopography = fromAdjacencyMaps . toList $ restrictKeys g1 testVertexSet
  where
    g1 = (flip restrictKeys testVertexSet) <$> adjacencyMap aws'

singleHopTransferTime :: Natural
                      -> BearerCharacteristics
                      -> BearerCharacteristics
                      -> DiffTime
singleHopTransferTime response_size i o
  = (fst . last)
    $ tcpRPCLoadPattern i o
          pdu_overhead initial_window Nothing request_size response_size
  where
    pdu_overhead = 20
    request_size = 256
    initial_window = 4 -- initial segments 2, 4 or 10 depending on O/S version

singleHopTimeToComplete :: Natural
                        -> AdjacencyMap (Edges BearerCharacteristics) NetNode
                        -> AdjacencyMap (Edges DiffTime) NetNode
singleHopTimeToComplete responseSize topography
  = fromAdjacencyMaps . toList $ mapWithKey ttc g
  where
    g = adjacencyMap topography
    ttc v = mapWithKey  (between v)
    between v v' out
      = Edges . (:[]) $
        singleHopTransferTime
          responseSize
          (fromEdge out)
          (fromEdge $ edgeLabel v' v topography)
    fromEdge :: Edges BearerCharacteristics -> BearerCharacteristics
    fromEdge = head . getEdges


simpleTest :: Natural -> AdjacencyMap (Edges DiffTime) NetNode
simpleTest n
  = singleHopTimeToComplete n testTopography

renderTest :: Show a => AdjacencyMap (Edges a) NetNode -> IO ()
renderTest am
  = mapM_ r $ edgeList am
  where
    r (e,a,b)
      = putStrLn $ show a ++ " -> "
          ++ show (head . getEdges $ e)
          ++ " -> " ++ show b

-- example usage:
-- look at the BearerCharacteristcs 
--    renderTest testTopography
-- look at the single hop time to ship distances
--    renderTest $ simpleTest $ 2 ^ 21
