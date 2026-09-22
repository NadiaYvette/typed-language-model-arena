{-# LANGUAGE GHC2024 #-}

-- | Skeleton of the backend-neutral @CodeGraphStore@ effect (Tier 1,
-- strategy B): a pure in-memory carrier over @nodes@/@edges@ so the four
-- acceptance contracts and the property laws can be exercised before the
-- SQLite/Postgres carriers land. Wire types mirror the Dhall/JSON schema
-- the façade will Mori-validate; line ranges are inclusive 1-based.
--
-- This module is deliberately free of I/O: the L4 contract SQL
-- (@docs/fixtures/codegraph-contracts.sql@) is the portable assertion set
-- for real carriers; these pure laws are the L1 gate for the effect's own
-- invariants (id stability, edge referential integrity, reindex idempotence).
module Campaign.CodeGraph
  ( NodeId,
    Node (..),
    Edge (..),
    Relation (..),
    GraphStore (..),
    emptyStore,
    upsertNode,
    insertEdge,
    findSymbol,
    getCallers,
    getCallees,
    tracePath,
    nodesWhere,
    reindexFile,
  )
where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

-- | Stable node id: the façade and contracts key on this, never on name alone.
type NodeId = Text

data Relation
  = RelDefines
  | RelCalls
  | RelImports
  | RelCites
  | RelContains
  deriving stock (Eq, Ord, Show, Generic)

data Node = Node
  { nodeId :: !NodeId,
    nodeRepo :: !Text,
    nodePath :: !Text,
    nodeName :: !Text,
    nodeType :: !Text,
    nodeLineStart :: !Int,
    nodeLineEnd :: !Int
  }
  deriving stock (Eq, Ord, Show, Generic)

data Edge = Edge
  { edgeSource :: !NodeId,
    edgeTarget :: !NodeId,
    edgeRelation :: !Relation
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | The carrier state: both maps keyed for O(log n) façade lookup.
data GraphStore = GraphStore
  { gsNodes :: !(Map.Map NodeId Node),
    gsEdges :: !(Set.Set Edge)
  }
  deriving stock (Eq, Show, Generic)

emptyStore :: GraphStore
emptyStore = GraphStore Map.empty Set.empty

-- | Idempotent node write: reindexing the same id with the same payload is
-- a no-op; a changed payload replaces (mtime+hash driven upstream).
upsertNode :: Node -> GraphStore -> GraphStore
upsertNode n gs = gs {gsNodes = Map.insert (nodeId n) n (gsNodes gs)}

-- | Edge insert with referential integrity: both endpoints must exist.
-- Callers that race a missing endpoint get the store unchanged (honest
-- refusal) rather than a dangling edge the façade would later crash on.
insertEdge :: Edge -> GraphStore -> GraphStore
insertEdge e gs
  | edgeSource e `Map.member` gsNodes gs
      && edgeTarget e `Map.member` gsNodes gs =
      gs {gsEdges = Set.insert e (gsEdges gs)}
  | otherwise = gs

-- | Façade tool: exact name match within a repo (or globally when repo is
-- empty). Empty list on unknown symbol — never throws (façade contract).
findSymbol :: Text -> Text -> GraphStore -> [Node]
findSymbol repo name gs =
  [ n
  | n <- Map.elems (gsNodes gs),
    nodeName n == name,
    T.null repo || nodeRepo n == repo
  ]

-- | Façade tool: nodes that call @targetId@ (in-edge, RelCalls).
getCallers :: NodeId -> GraphStore -> [Node]
getCallers targetId gs =
  [ n
  | e <- Set.toList (gsEdges gs),
    edgeTarget e == targetId,
    edgeRelation e == RelCalls,
    Just n <- [Map.lookup (edgeSource e) (gsNodes gs)]
  ]

-- | Façade tool: nodes the source calls (out-edge, RelCalls).
getCallees :: NodeId -> GraphStore -> [Node]
getCallees sourceId gs =
  [ n
  | e <- Set.toList (gsEdges gs),
    edgeSource e == sourceId,
    edgeRelation e == RelCalls,
    Just n <- [Map.lookup (edgeTarget e) (gsNodes gs)]
  ]

-- | Façade tool: BFS over RelCalls (and RelImports for module reachability),
-- capped so a cyclic graph terminates. Empty when the start id is unknown.
tracePath :: NodeId -> Int -> GraphStore -> [Node]
tracePath start maxDepth gs = case Map.lookup start (gsNodes gs) of
  Nothing -> []
  Just _ -> go Set.empty [start] 0
  where
    go _ [] _ = []
    go seen frontier d
      | d > maxDepth = []
      | otherwise =
          let nextIds =
                [ edgeTarget e
                | i <- frontier,
                  e <- Set.toList (gsEdges gs),
                  edgeSource e == i,
                  edgeRelation e `elem` [RelCalls, RelImports],
                  edgeTarget e `notElem` seen
                ]
              nodes' =
                [ n
                | i <- frontier,
                  Just n <- [Map.lookup i (gsNodes gs)]
                ]
           in nodes' <> go (foldr Set.insert seen frontier) (Set.toList (Set.fromList nextIds)) (d + 1)

-- | Contract-style filter (mirrors the SQL WHERE clauses in the fixture).
nodesWhere :: (Node -> Bool) -> GraphStore -> [Node]
nodesWhere p gs = filter p (Map.elems (gsNodes gs))

-- | Reindex one path: drop every node/edge for that path, then upsert the
-- replacements. Laws: idempotent for identical input; unchanged files keep
-- their ids (they are never touched).
reindexFile :: Text -> [Node] -> [Edge] -> GraphStore -> GraphStore
reindexFile path newNodes newEdges gs =
  let staleIds =
        Set.fromList
          [ nodeId n
          | n <- Map.elems (gsNodes gs),
            nodePath n == path
          ]
      gs' =
        gs
          { gsNodes = foldr Map.delete (gsNodes gs) staleIds,
            gsEdges = Set.filter (\e -> edgeSource e `Set.notMember` staleIds && edgeTarget e `Set.notMember` staleIds) (gsEdges gs)
          }
      gs'' = foldr upsertNode gs' newNodes
   in foldr insertEdge gs'' newEdges
