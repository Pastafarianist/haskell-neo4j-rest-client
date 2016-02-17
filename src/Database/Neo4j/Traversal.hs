{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE TypeSynonymInstances  #-}
{-# LANGUAGE FlexibleInstances  #-}

-- | Module to manage traversal operations

module Database.Neo4j.Traversal (
    -- * Types for configuring the traversal
    Uniqueness(..), TraversalOrder(..), ReturnFilter(..), RelFilter, TraversalDesc(..),
    -- * Additional types for configuring a paged traversal
    TraversalPaging(..),
    -- * Types used when returning paths
    ConcreteDirection(..), Path(..), IdPath, FullPath,
    -- * Types used when returning paged results
    PagedTraversal, pathNodes, pathRels, 
    -- * Traversal operations
    traverseGetNodes, traverseGetRels, traverseGetPath, traverseGetFullPath,
    -- * Paged traversal operations
    pagedTraverseGetNodes, pagedTraverseGetRels, pagedTraverseGetPath, pagedTraverseGetFullPath,
    -- * Operations to handle paged results
    getPagedValues, nextTraversalPage, pagedTraversalDone) where

import Data.Default

import Prelude hiding (traverse)

import Control.Applicative
import Control.Exception.Base (throw, catch)
import Control.Monad (mzero)
import Data.Aeson ((.=), (.:), (.:?))
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.String (fromString)

import qualified Data.Aeson as J
import qualified Data.ByteString.Char8 as S
import qualified Data.ByteString.Lazy as L
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Network.HTTP.Types as HT
import qualified Network.URI as NU

import Database.Neo4j.Types
import Database.Neo4j.Http

-- | Different types of uniqueness calculations for a traversal
data Uniqueness = NodeGlobal | RelationshipGlobal | NodePathUnique | RelationshipPath deriving (Eq, Show)

-- | Traversal mode
data TraversalOrder = BreadthFirst | DepthFirst deriving (Eq, Show)

-- | Built-in return filters
data ReturnFilter = ReturnAll | ReturnAllButStartNode deriving (Eq, Show)

type RelFilter = (RelationshipType, Direction)
newtype RelFilterT = RelFilterT {runRelFilter :: RelFilter} -- Useful to make a ToJSON instance of the type alias

newtype MaybeUniqueness = MaybeUniqueness {runMaybeUniqueness :: Maybe Uniqueness} -- Useful for ToJSON of type alias

-- | Type containing all info describing a traversal request
data TraversalDesc = TraversalDesc {
    travOrder :: TraversalOrder,
    travRelFilter :: [RelFilter],
    travUniqueness :: Maybe Uniqueness,
    travDepth :: Either Integer T.Text,
    travNodeFilter :: Either ReturnFilter T.Text} deriving (Eq, Show)

-- | Get the body for a traversal request
traversalReqBody :: TraversalDesc -> L.ByteString
traversalReqBody (TraversalDesc ord relfilt uniq depth nodefilt) = J.encode $ J.object [
        "order" .= J.toJSON ord,
        "relationships" .= map RelFilterT relfilt,
        "uniqueness" .= MaybeUniqueness uniq,
        depthField depth,
        "return_filter" .= returnField nodefilt
        ]
    where depthField (Left lvl) = "max_depth" .= lvl
          depthField (Right desc) = "prune_evaluator" .= J.object ["language" .= ("javascript" :: T.Text),
                                                                   "body" .= desc]
          returnField (Left filt) = J.object ["language" .= ("builtin" :: T.Text), "name" .= filt]
          returnField (Right desc) = J.object ["language" .= ("javascript" :: T.Text), "body" .= desc]

-- | How to codify traversalDesc values into JSON
instance J.ToJSON TraversalOrder where
    toJSON BreadthFirst = J.String "breadth_first"
    toJSON DepthFirst = J.String "depth_first"

-- | How to codify ReturnFilter values into JSON
instance J.ToJSON ReturnFilter where
    toJSON ReturnAll = J.String "all"
    toJSON ReturnAllButStartNode = J.String "all_but_start_node"

-- | How to codify RelFilter values into JSON
instance J.ToJSON RelFilterT where
    toJSON (RelFilterT (rType, dir)) = J.object ["direction" .= dirToJson dir, "type" .= J.toJSON rType]
        where dirToJson Outgoing = J.String "out"
              dirToJson Incoming = J.String "in"
              dirToJson Any = J.String "all"

-- | How to codify uniqueness values into JSON
instance J.ToJSON MaybeUniqueness where
    toJSON (MaybeUniqueness Nothing) = J.String "none"
    toJSON (MaybeUniqueness (Just NodeGlobal)) = J.String "node_global"
    toJSON (MaybeUniqueness (Just RelationshipGlobal)) = J.String "relationship_global"
    toJSON (MaybeUniqueness (Just NodePathUnique)) = J.String "node_path"
    toJSON (MaybeUniqueness (Just RelationshipPath)) = J.String "relationship_path"

instance Default TraversalDesc where
    def = TraversalDesc {travOrder = BreadthFirst, travRelFilter = [], travUniqueness = Nothing,
                         travDepth = Left 1, travNodeFilter = Left ReturnAll}

-- | Description of a traversal paging
data TraversalPaging = TraversalPaging {
    pageSize :: Integer,
    pageLeaseSecs :: Integer
    } deriving (Eq, Show)

instance Default TraversalPaging where
    def = TraversalPaging {pageSize = 50, pageLeaseSecs = 60}

-- | Direction without possibility of ambiguity
data ConcreteDirection = In | Out deriving (Eq, Show, Ord)

instance J.FromJSON ConcreteDirection where
    parseJSON (J.String "->" ) =  return Out
    parseJSON (J.String "<-" ) =  return In
    parseJSON _ = mzero

-- | Data type to describe a path in a graph, that is a single node or nodes interleaved with relationships
data Path a b = PathEnd !a | PathLink !a !b !(Path a b) deriving (Eq, Ord, Show)

-- | Get all the nodes of a path
pathNodes :: Path a b -> [a]
pathNodes (PathEnd n) = [n]
pathNodes (PathLink n _ p) = n : pathNodes p

-- | Get all the relationships of a path
pathRels :: Path a b -> [b]
pathRels (PathEnd _) = []
pathRels (PathLink _ r p) = r : pathRels p

-- | Path that its data are id's
type IdPath = Path NodePath (RelPath, ConcreteDirection)

-- | How to decodify an IdPath from JSON
instance J.FromJSON IdPath where
    parseJSON (J.Object v) =  do
                  nodes <- (map (getNodePath . NodeUrl)) <$> (v .: "nodes")
                  rels <- (map (getRelPath . RelUrl)) <$> (v .: "relationships")
                  -- Pre 2.2 neo4j versions don't provide the directions field, so we put a default value...
                  dirs <- fromMaybe (take (length rels) $ repeat Out) <$> v .:? "directions"
                  let correctPath = (length nodes) == (length rels + 1) && (length rels == length dirs) 
                  if correctPath
                    then return $ buildPath nodes rels dirs
                    else fail $ "Wrong path nodes: " <> show nodes <> " rels: " <> show rels <> " dirs: " <> show dirs
        where buildPath [n] [] [] = PathEnd n
              buildPath (n:ns) (r:rs) (d:ds) = PathLink n (r, d) (buildPath ns rs ds)
              buildPath _ _ _ = undefined
    parseJSON _ = fail "wrong type for path"

-- | Path that its data are full nodes and relationships, not only their id's
type FullPath = Path Node Relationship

-- | How to decodify an IdPath from JSON
instance J.FromJSON FullPath where
    parseJSON (J.Object v) =  do
                  nodes <- v .: "nodes"
                  rels <- v .: "relationships"
                  let correctPath = length nodes == length rels + 1
                  if correctPath
                    then return $ buildPath nodes rels
                    else fail $ "Wrong path nodes: " <> show nodes <> " rels: " <> show rels
        where buildPath [n] [] = PathEnd n
              buildPath (n:ns) (r:rs) = PathLink n r (buildPath ns rs)
              buildPath _ _ = undefined
    parseJSON _ = fail "wrong type for path"

-- | Data type that holds a result for a paged traversal with the URI to get the rest of the pages
data PagedTraversal a = Done | More S.ByteString [a] deriving (Eq, Ord, Show)

-- | Get the path of a node in simple text
bsNodePath :: NodeIdentifier a => a -> S.ByteString
bsNodePath n = TE.encodeUtf8 $ (runNodePath $ getNodePath n)

-- | Get the path for a traversal starting from a node
traversalApi :: NodeIdentifier a => a -> S.ByteString
traversalApi n = bsNodePath n <> "/traverse"

-- | Get the path for a paged traversal starting from a node
pagedApi :: NodeIdentifier a => a -> S.ByteString
pagedApi n = bsNodePath n <> "/paged/traverse"

-- | Wrap 404 exception into Neo4jNoEntity exceptions
proc404 :: NodeIdentifier n => n -> Neo4jException -> a
proc404 n exc@(Neo4jUnexpectedResponseException s)
        | s == HT.status404 = throw (Neo4jNoEntityException $ bsNodePath n)
        | otherwise = throw exc
proc404 _ exc = throw exc

-- | Perform a traversal operation
traverse :: (NodeIdentifier a, J.FromJSON b) => S.ByteString -> TraversalDesc -> a -> Neo4j [b]
traverse path desc start = Neo4j $ \conn ->
                             httpCreate conn (traversalApi start <> path) (traversalReqBody desc) `catch` proc404 start

-- | Perform a traversal and get the resulting nodes
traverseGetNodes :: NodeIdentifier a => TraversalDesc -> a -> Neo4j [Node]
traverseGetNodes = traverse "/node"

-- | Perform a traversal and get the resulting relationship entities
traverseGetRels :: NodeIdentifier a => TraversalDesc -> a -> Neo4j [Relationship]
traverseGetRels = traverse "/relationship"

-- | Perform a traversal and get the resulting node and relationship paths
--   IMPORTANT! In pre 2.2 Neo4j versions the directions in each relationship ID returned have a default value
--   (The API does not provide them)
traverseGetPath :: NodeIdentifier a => TraversalDesc -> a -> Neo4j [IdPath]
traverseGetPath = traverse "/path"

-- | Perform a traversal and get the resulting node and relationship entities
traverseGetFullPath :: NodeIdentifier a => TraversalDesc -> a -> Neo4j [FullPath]
traverseGetFullPath = traverse "/fullpath"

-- | Get the values of a paged traversal result
getPagedValues :: PagedTraversal a -> [a]
getPagedValues Done = []
getPagedValues (More _ r)  = r

-- | Get the next page of values from a traversal result
nextTraversalPage :: J.FromJSON a => PagedTraversal a -> Neo4j (PagedTraversal a)
nextTraversalPage Done = return Done
nextTraversalPage (More pagingUri _) = Neo4j $ \conn -> do
    mr <- httpRetrieve conn pagingUri
    return $ case mr of
               Nothing -> Done
               Just r -> More pagingUri r

-- | Whether a paged traversal is done
pagedTraversalDone :: PagedTraversal a -> Bool
pagedTraversalDone Done = True
pagedTraversalDone _ = False

-- | Generate the query string associated to a paging description
pagingQs :: TraversalPaging -> S.ByteString
pagingQs (TraversalPaging pSize leaseSecs) = "?pageSize=" <> showBs pSize <> "&leaseTime=" <> showBs leaseSecs
    where showBs = fromString . show

-- | Perform a paged traversal and get the resulting nodes
pagedTraversal :: (NodeIdentifier a, J.FromJSON b) => S.ByteString -> TraversalDesc -> TraversalPaging -> a
               -> Neo4j (PagedTraversal b)
pagedTraversal path desc paging start = Neo4j $ \conn -> do
    (r, headers) <- httpCreateWithHeaders conn (pagedApi start <> path <> pagingQs paging) (
        traversalReqBody desc) `catch` proc404 start
    let location = fromMaybe "" $ do
        loc <- (S.unpack . snd) <$> find ((==HT.hLocation) . fst) headers
        (S.pack . NU.uriPath) <$> NU.parseURI loc
    return (More location r)

-- | Perform a paged traversal and get the resulting nodes
pagedTraverseGetNodes :: NodeIdentifier a => TraversalDesc -> TraversalPaging -> a -> Neo4j (PagedTraversal Node)
pagedTraverseGetNodes = pagedTraversal "/node"

-- | Perform a paged traversal and get the resulting relationships 
pagedTraverseGetRels :: NodeIdentifier a => TraversalDesc -> TraversalPaging -> a -> Neo4j(PagedTraversal Relationship)
pagedTraverseGetRels = pagedTraversal "/relationship"

-- | Perform a paged traversal and get the resulting id paths,
--   IMPORTANT! In pre 2.2 Neo4j versions the directions in each relationship ID returned have a default value
--   (The API does not provide them)
pagedTraverseGetPath :: NodeIdentifier a => TraversalDesc -> TraversalPaging -> a -> Neo4j (PagedTraversal IdPath)
pagedTraverseGetPath = pagedTraversal "/path"

-- | Perform a paged traversal and get the resulting paths with full entities
pagedTraverseGetFullPath :: NodeIdentifier a => TraversalDesc -> TraversalPaging -> a -> Neo4j(PagedTraversal FullPath)
pagedTraverseGetFullPath = pagedTraversal "/fullpath"
