module CodeWidgetUtil where

import qualified Graphics.UI.Gtk            as G
import Text.Parsec
import Text.Parsec.Pos
import Data.List
import Util
import CodeWidgetTypes

--dbgPrints :: Bool
dbgPrints = False
dbgPrints = True
mpStrLn :: String -> IO ()
mpStrLn s = do case dbgPrints of
                    True  -> putStrLn s
                    False -> return ()

getPage :: CodeView -> PageID -> Maybe PageContext
getPage cv p =
    let pgs = filter (\x -> p == (pgID x)) $ cvPages cv
    in case pgs of 
            [] -> Nothing
            _  -> Just (head pgs)

-- get the specified page and region contexts, maybe
getContexts :: CodeView -> Region -> Maybe CwRef
getContexts cv r = 
    let pgs = filter (\x -> (pid r) == (pgID x)) $ cvPages cv
    in case pgs of 
            [] -> Nothing
            _  -> let pc = head pgs
                      rgs = filter (\x -> (rid r) == (rcRegion x)) (pgRegions pc)
                  in case rgs of 
                          [] -> Nothing
                          _  -> Just (pc, (head rgs))

-- get the specified region context, maybe
getRegion :: PageContext -> RegionID -> Maybe RegionContext
getRegion pg r = 
    let rgs = filter (\x -> r == (rcRegion x)) $ pgRegions pg
    in case rgs of 
            [] -> Nothing
            _  -> Just (head rgs)
    
-- get a list of all regions except the specified one
otherRegions :: PageContext -> RegionID -> [RegionContext]
otherRegions pg r = filter (\x -> r /= (rcRegion x)) $ pgRegions pg

-- get a list of all pages except the specified one
otherPages :: CodeView -> PageID -> [PageContext]
otherPages cv p = filter (\x -> p /= (pgID x)) $ cvPages cv

-- get a list if all subregions of this region
childRegions :: PageContext -> RegionContext -> [RegionContext]
childRegions pg r = filter (\x -> rcRegion r == (rcParent x)) $ pgRegions pg

-- return a list of all editable regions
editableRgns :: PageContext -> [RegionContext]
editableRgns pg = filter rcEditable (pgRegions pg)

-- Get a list of regions which are nested in the specified region
subRegions :: PageContext -> RegionContext -> [RegionContext]
subRegions pg rc = sort $ childRegions pg rc

-- is specified region the rootRegion?
isRoot :: RegionContext -> Bool
isRoot rc = if' (rcRegion rc == rootRegion) True False

-- create a new left-side mark
newLeftMark :: IO G.TextMark
newLeftMark = do mk <- G.textMarkNew Nothing True
                 G.textMarkSetVisible mk False
                 return mk

-- create a new right-side mark
newRightMark :: IO G.TextMark
newRightMark = do mk <- G.textMarkNew Nothing False
                  G.textMarkSetVisible mk False
                  return mk

-- Get a TextIter set to the start of the region
rgnStart ::  PageContext -> RegionContext -> IO G.TextIter
rgnStart pg rc = do
    G.textBufferGetIterAtMark (pgBuffer pg) (rcStart rc)

-- Get a TextIter set to the end of the region
rgnEnd :: PageContext -> RegionContext -> IO G.TextIter
rgnEnd pg rc = do
    G.textBufferGetIterAtMark ( pgBuffer pg) (rcEnd rc)

-- convert a TextIter into a SourcePos
posFromIter :: PageContext -> G.TextIter -> IO SourcePos
posFromIter pg iter = do
    l <- G.textIterGetLine iter
    c <- G.textIterGetLineOffset iter
    return $ newPos (pgFileName pg) (l + 1)  (c + 1)


-- convert a root-relative position to a subregion-relative position
mapPosToRgn :: PageContext -> RegionContext -> SourcePos -> IO SourcePos
mapPosToRgn pg rc pos = do
    sp <- rgnStartPos pg rc
    return $ newPos (pgFileName pg) ((sourceLine pos) - (sourceLine sp) + 1) ((sourceColumn pos) - (sourceColumn sp) + 1)

-- get region's current starting SourcePos - 
rgnStartPos :: PageContext -> RegionContext -> IO SourcePos
rgnStartPos pg rc = do
    iter <- rgnStart pg rc
    posFromIter pg iter

-- get region's initial position - may be different from current starting SourcePos due to edits to preceeding regions
rgnInitPos :: PageContext -> RegionContext -> SourcePos
rgnInitPos _ rc = rcStartPos rc

-- get region's initial line
rgnInitLine pg rc = sourceLine (rgnInitPos pg rc)

-- get region's ending SourcePos
rgnEndPos :: PageContext -> RegionContext -> IO SourcePos
rgnEndPos pg rc = do
    iter <- rgnEnd pg rc
    posFromIter pg iter

-- return the number of lines in a region
rgnHeight :: PageContext -> RegionContext -> IO Line
rgnHeight pg rc = do
    spos <- rgnStartPos pg rc
    epos <- rgnEndPos pg rc
    --hm <- mapM (rgnHeight pg) (childRegions pg rc)
    --let ch = foldl (+) 0 hm  
    --return $ (sourceLine epos) - (sourceLine spos) - (rcInitHeight rc) - ch
    return $ (sourceLine epos) - (sourceLine spos) - (rcInitHeight rc)

-- return the width of a region - the difference bewteen the region's position at creating and its current ending position column
rgnWidth :: PageContext -> RegionContext -> IO Column
rgnWidth pc rc = do
    spos <- rgnStartPos pc rc
    epos <- rgnEndPos pc rc
    --wm <- mapM (rgnWidth pc) (childRegions pc rc)
    --let cw = foldl (+) 0 wm
    --return $ (sourceColumn epos) - (sourceColumn spos) - (rcInitWidth rc) - cw
    return $ (sourceColumn epos) - (sourceColumn spos) - (rcInitWidth rc)

-- Get a root-normalized TextIter for the given position
rootIterFromPos :: PageContext -> SourcePos -> IO G.TextIter
rootIterFromPos pg pos = do
    G.textBufferGetIterAtLineOffset (pgBuffer pg)  (sourceLine pos - 1)  (sourceColumn pos - 1)

