{-# LANGUAGE RecordWildCards #-}

module CodeWidget.CodeWidgetAPI where

import Data.Maybe
import Data.List
import qualified Graphics.UI.Gtk            as G
import qualified Graphics.UI.Gtk.SourceView as G
import Text.Parsec
import Text.Parsec.Pos
import Data.IORef
import Util
import CodeWidget.CodeWidgetTypes
import CodeWidget.CodeWidgetUtil
import CodeWidget.CodeWidgetInternal
import CodeWidget.CodeWidgetSBar


-- Individual API functions

codePageCreate :: RCodeView -> String -> IO Region
codePageCreate ref f = do
    cv <- readIORef ref
    let lng  = cvLanguage cv
    let font = cvFont cv
    let nb   = cvNotebook cv
    txt <- readFile f

    vbox <- G.vBoxNew False 0
    G.widgetShow vbox
    scroll <- G.scrolledWindowNew Nothing Nothing
    G.widgetShow scroll
    G.boxPackStart vbox scroll G.PackGrow 0

    table <- G.textTagTableNew
    buf <- G.sourceBufferNew (Just table)
    etag <- G.textTagNew Nothing
    G.set etag [G.textTagEditable G.:= False]
    G.textTagTableAdd table etag
    G.textTagSetPriority etag 0
    G.sourceBufferSetLanguage buf (Just lng)
    G.sourceBufferSetHighlightSyntax buf True
    v <- G.sourceViewNewWithBuffer buf
    
    G.set v [ G.sourceViewAutoIndent  G.:= True,
              G.sourceViewIndentWidth G.:= 4,
              G.sourceViewTabWidth G.:= 4,
              G.sourceViewInsertSpacesInsteadOfTabs G.:= True
            ]

    G.widgetModifyFont v $ Just font
    G.textViewSetEditable v True
    G.widgetShow v
    G.containerAdd scroll v

    pgid <- G.notebookAppendPage nb vbox f
    root <- mkRootRegion pgid buf table

    apiStrLn $ "CW# pageCreate: file:" ++ show f ++ " pg:" ++ show pgid
    let newpg = PageContext { pgID         = pgid
                            , pgView       = v
                            , pgBuffer     = buf
                            , pgTagTable   = table
                            , pgEditTag    = etag
                            , pgNextRegion = (rootRegion + 1)
                            , pgRegions    = [root]
                            , pgFileName   = f
                            }

    writeIORef ref cv { cvPages = newpg:(cvPages cv)}
    iter <- G.textBufferGetStartIter buf
    cvRgnInsertText newpg iter txt
    iter <- G.textBufferGetStartIter buf
    G.textBufferPlaceCursor buf iter
    nbi <- cvCurPage cv
    csbCursUpdate cv nbi

    -- setup signal handlers
    -- buf signals
    _ <- G.on    buf G.deleteRange      (bufSigDeleteRange ref)
    _ <- G.after buf G.bufferInsertText (bufSigInsertText ref)
    _ <- G.after v   G.pasteClipboard   (viewSigPasteClibB  ref)
    _ <- G.on    v   G.keyReleaseEvent  (viewKeyRelease ref)
    _ <- G.after v   G.moveCursor       (csbCursMove ref)
    _ <- G.after v   G.moveFocus        (csbFocusMove ref)
    _ <- G.after buf G.markSet          (csbMarkSet ref)

    return $ Region pgid rootRegion

codeRegionUnderCursor :: RCodeView -> IO (Maybe (Region, SourcePos))
codeRegionUnderCursor ref = do
    CodeView{..} <- readIORef ref
    pageid <- G.notebookGetCurrentPage cvNotebook
    let pc = fromJust $ find ((== pageid) . pgID) cvPages
    curpos <- cvCursorPos pc
    mrc <- cvWhoHoldsPos pc curpos
    maybe (return Nothing)
          (\rc -> do sp <- rgnStartPos pc rc
                     let lin = sourceLine curpos - sourceLine sp
                         col = if' (lin == 0) (sourceColumn curpos - sourceColumn sp + 1) (sourceColumn curpos)
                     return $ Just (Region pageid (rcRegion rc), newPos (sourceName curpos) (lin + 1) col)) 
          mrc

codeRegionCreate :: RCodeView -> Region -> SourcePos -> Bool -> String -> IO () -> IO Region
codeRegionCreate ref parent pos ed txt f = do
    cv <- readIORef ref
    case getContexts cv parent of
          Nothing           -> error ("regionCreate: cannot find notebook page " ++ (show (pid parent)))
          Just (ctx@(pg,x)) -> do 
                                  r <- cvRgnCreateEmpty ref ctx pos ed f
                                  codeRegionSetText ref r txt
                                  apiStrLn $ "CW# regionCreate: pg:" ++ show (pgID pg) ++ " rg:" ++ show (rcRegion x) ++ " pos:" ++ show pos ++ " ed:" ++ show ed ++ " Region:" ++ show (rid r)
                                  return r
                      
codeRegionCreateFrom :: RCodeView -> Region -> (SourcePos, SourcePos) -> Bool -> IO () -> IO Region
codeRegionCreateFrom ref parent (from, to) ed f = do
    cv <- readIORef ref
    case getContexts cv parent of
          Nothing  -> error ("regionCreateFrom: cannot find parent region " ++ (show parent))
          Just (ctx@(pg,x)) -> do 
                                  r <- cvRgnCreateFrom ref ctx from to ed False f
                                  apiStrLn $ "CW# regionCreateFrom: pg:" ++ show (pgID pg) ++ " rg:" ++ show (rcRegion x) ++ " fm:" ++ show from ++ " to:" ++ show to ++ " ed:" ++ show ed ++ " Region:" ++ show (rid r)
                                  --codeDumpRegions ref parent
                                  return r
                      
codeRegionEditable :: RCodeView -> Region -> Bool -> IO ()
codeRegionEditable ref r b = do
    cv <- readIORef ref
    case getContexts cv r of
          Nothing  -> error ("regionEditable: cannot find region " ++ (show r))
          Just (p,x) -> if ([] == childRegions p x) 
                            then do  apiStrLn $ "CW# regionEditable: pg:" ++ show (pgID p) ++ " rg:" ++ show (rcRegion x) ++ " ed:" ++ show b
                                     let nx = x{rcEditable = b}
                                     let ox = otherRegions p (rcRegion x) 
                                     let np = p {pgRegions = nx:ox}
                                     let op = otherPages cv (pgID p)
                                     writeIORef ref cv {cvPages = np:op}
                                     --rgnSetMarkVis np nx
                                     cvSetEditFlags np 
                                     return ()
                            else error ("regionEditable: cannot change region with nested subregions")
                              
                      
codeRegionDelete :: RCodeView -> Region -> IO ()
codeRegionDelete ref r = do
    cv <- readIORef ref
    if ((rid r) > 0) 
        then case getContexts cv r of 
                  Nothing -> error ("regionDelete: specified region does not exist: " ++ (show r))
                  Just ctx  -> do let pg = fst ctx
                                  let x = snd ctx
                                  apiStrLn $ "CW# regionDelete: pg:" ++ show (pgID pg) ++ " rg:" ++ show (rcRegion x)
                                  si <- rgnStart pg x
                                  ei <- rgnEnd   pg x
                                  G.textBufferRemoveTag (pgBuffer pg) (rcBgTag x) si ei
                                  let newrgns = otherRegions pg (rcRegion x)
                                  G.textBufferDeleteMark (pgBuffer pg) (rcStart x)
                                  G.textBufferDeleteMark (pgBuffer pg) (rcEnd x)
                                  let npg = pg {pgRegions = newrgns}
                                  let ops = otherPages cv (pgID npg)
                                  let ncv = cv {cvPages = npg:ops}
                                  writeIORef ref ncv
                                  cvSetEditFlags npg 
                                  --codeDumpRegions ref r
        else if' ((rid r) == 0) (error "regionDelete: attempt to delete root region!") (error $ "regionDelete: invalid negative region " ++ (show r))


codeRegionGetText :: RCodeView -> Region -> IO String
codeRegionGetText ref r = do
    cv <- readIORef ref
    case getContexts cv r of 
            Nothing      -> error ("regionGetText: region not found: " ++ (show r))
            Just (pg,rc) -> cvSubRgnText pg rc


codeRegionGetBoundedText :: RCodeView -> Region -> (SourcePos, SourcePos) -> IO String
codeRegionGetBoundedText ref r (from, to) = do
    cv <- readIORef ref
    case getContexts cv r of 
            Nothing      -> error ("regionGetBoundedText: region not found: " ++ (show r))
            Just (pg,rc) -> do 
                               apiStrLn $ "CW# regionGetBoundedText: pg: " ++ show (pgID pg) ++ " rg:" ++ show (rcRegion rc) ++ " Fm:" ++ show from ++ " To:" ++ show to
                               s <- rgnMapPos pg rc from
                               e <- rgnMapPos pg rc to
                               si <- rootIterFromPos pg s
                               ei <- rootIterFromPos pg e
                               cvRgnGetText pg si ei False



codeRegionSetText :: RCodeView -> Region -> String -> IO ()
codeRegionSetText ref r txt = do
    cv <- readIORef ref
    case getContexts cv r of 
            Nothing      -> error ("regionSetText: region not found: " ++ (show r))
            Just (pg,rc) -> do apiStrLn $ "CW# regionSetText: pg: " ++ show (pgID pg) ++ " rg:" ++ show (rcRegion rc) ++ " Text:" ++ show txt
                               if (isRoot rc) 
                                  then do G.textBufferSetText (pgBuffer pg) txt
                                  else do iter1 <- rgnStart pg rc
                                          iter2 <- rgnEnd pg rc
                                          G.textBufferDelete (pgBuffer pg) iter1 iter2
                                          G.textBufferInsert (pgBuffer pg) iter1 txt
                                          cvSetEditFlags pg 

codeRegionInsertText :: RCodeView -> Region -> String -> IO ()
codeRegionInsertText ref r t = do
    cv <- readIORef ref  
    case getContexts cv r of 
            Nothing      -> error ("regionInsertText: region not found: " ++ (show r))
            Just (pg,x)  -> do apiStrLn $ "CW# regionInsertText: pg: " ++ show (pgID pg) ++ " rg:" ++ show (rcRegion x) ++ " Text:" ++ show t
                               di  <- cvInsertMark ref pg x
                               i3  <- G.textBufferGetIterAtMark (pgBuffer pg) di
                               cvRgnInsertText pg i3 t
                               cvSetEditFlags pg 

codeRegionDeleteText :: RCodeView -> Region -> (SourcePos, SourcePos) -> IO ()
codeRegionDeleteText ref r (from, to) = do
    cv <- readIORef ref  
    case getContexts cv r of 
            Nothing     -> error ("regionDeleteText: region not found: " ++ (show r))
            Just (pg,x) -> do apiStrLn $ "CW# regiondeleteText: pg: " ++ show (pgID pg) ++ " rg:" ++ show (rcRegion x) ++ " fm:" ++ show from ++ " to:" ++ show to
                              s <- rgnMapPos pg x from
                              e <- rgnMapPos pg x to
                              si <- rootIterFromPos pg s
                              ei <- rootIterFromPos pg e
                              G.textBufferDelete (pgBuffer pg) si ei
    
codeGetAllText :: RCodeView -> Region -> IO String
codeGetAllText ref r = do
    cv <- readIORef ref
    case getPage cv (pid r) of 
          Nothing -> error "regionGetAllText: bad Region"
          Just pg -> do apiStrLn $ "CW# regionGetAllText: pg:" ++ show (pgID pg)
                        cvGetAllText pg (rid r)


codeTagNew :: RCodeView -> Region -> IO G.TextTag
codeTagNew ref r = do 
    cv  <- readIORef ref
    tag <- G.textTagNew Nothing
    case getContexts cv r of 
          Nothing      -> error "tagNew: bad Region"
          Just (pg,rc) -> do apiStrLn $ "CW# tagNew: pg:" ++ show (pgID pg) ++ " Rg:" ++ show (rcRegion rc)
                             G.textTagTableAdd (pgTagTable pg) tag
                             return tag


codeRegionApplyTag :: RCodeView -> Region -> G.TextTag -> (SourcePos, SourcePos) -> IO ()
codeRegionApplyTag ref r t (from, to) = do
    cv <- readIORef ref
    case getContexts cv r of 
            Nothing     -> error ("regionApplyTag: region not found: " ++ (show r))
            Just (pg,x) -> do  rfrom <- rgnMapPos pg x from
                               rto   <- rgnMapPos pg x to
                               siter <- rootIterFromPos pg rfrom
                               eiter <- rootIterFromPos pg rto
                               -- cvSetMyPage cv pg
                               apiStrLn $ "CW# regionApplyTag: pg:" ++ show (pgID pg) ++ " Rg:" ++ show (rcRegion x) ++ " Fm:" ++ show rfrom ++ " to:" ++ show rto
                               G.textBufferApplyTag (pgBuffer pg) t siter eiter


codeRegionRemoveTag :: RCodeView -> Region -> G.TextTag -> IO ()
codeRegionRemoveTag ref r t = do
    cv <- readIORef ref
    case getContexts cv r of 
            Nothing     -> error ("regionRemoveTag: region not found: " ++ (show r))
            Just (pg,x) -> do apiStrLn $ "CW# regionRemoveTag: pg:" ++ show (pgID pg) ++ " Rg:" ++ show (rcRegion x) 
                              iter1 <- rgnStart pg x
                              iter2 <- rgnEnd pg x
                              G.textBufferRemoveTag (pgBuffer pg) t iter1 iter2


codeRegionSetMark :: RCodeView -> Region -> G.TextMark -> SourcePos -> IO ()
codeRegionSetMark ref r m p = do
    cv <- readIORef ref
    case getContexts cv r of
            Nothing     -> error ("regionSetMark: region not found: " ++ (show r))
            Just (pg,x) -> do rpos <- rgnMapPos pg x p
                              iter <- G.textBufferGetIterAtLineOffset (pgBuffer pg) (sourceLine rpos - 1) (sourceColumn rpos - 1) 
                              G.textBufferAddMark (pgBuffer pg) m iter

codeRegionGetIter :: RCodeView -> Region -> SourcePos -> IO G.TextIter
codeRegionGetIter ref r p = do
    cv <- readIORef ref
    case getContexts cv r of
            Nothing     -> error ("regionGetIter: region not found: " ++ (show r))
            Just (pg,x) -> do rpos <- rgnMapPos pg x p
                              G.textBufferGetIterAtLineOffset (pgBuffer pg) (sourceLine rpos - 1) (sourceColumn rpos - 1)
                        
codeRegionGetSelection :: RCodeView -> Region -> IO (Maybe CwSelection)
codeRegionGetSelection ref r = do
    cv <- readIORef ref
    case getContexts cv r of 
          Nothing      -> error "regionGetSelection: bad Region"
          Just (pg, x) -> do  hassel <- G.textBufferHasSelection (pgBuffer pg)
                              case hassel of 
                                    False -> return Nothing
                                    True  -> do (ifm,ito) <- G.textBufferGetSelectionBounds (pgBuffer pg)
                                                pfm <- posFromIter pg ifm
                                                pto <- posFromIter pg ito
                                                apiStrLn $ "CW# regionGetSelection: From:" ++ show pfm ++ " To:" ++ show pto
                                                mrc <- cvWhoHoldsPos pg pfm
                                                case mrc of 
                                                      Nothing -> return Nothing
                                                      Just rc -> do sp <- mapPosToRgn pg rc pfm
                                                                    ep <- mapPosToRgn pg rc pto
                                                                    apiStrLn $ "CW# getSel: R:" ++ show (rcRegion rc) ++ " ST:" ++ show sp ++ " ED:" ++ show ep
                                                                    let rgn = Region (pgID pg) (rcRegion rc)
                                                                    return $ Just (CwSelection rgn sp ep)
                                            
                   

codeRegionScrollToPos :: RCodeView -> Region -> SourcePos -> IO ()
codeRegionScrollToPos ref r pos = do
    cv <- readIORef ref
    case getContexts cv r of
            Nothing     -> error ("regionScrollToPos: region not found: " ++ (show r))
            Just (pg,x) -> do 
                              apiStrLn $ "CW# regionScrollToPos: pg:" ++ show (pgID pg) ++ " Rg:" ++ show (rcRegion x) ++ " Pos:" ++ show pos
                              rpos <- rgnMapPos pg x pos
                              t3   <- rootIterFromPos pg rpos
                              cvSetMyPage cv pg
                              _    <- G.textViewScrollToIter (pgView pg) t3 0.1 Nothing
                              return ()


codeDumpRegions :: RCodeView -> Region -> IO ()
codeDumpRegions ref r = do
    cv <- readIORef ref
    case getPage cv (pid r) of
            Nothing  -> error ("dumpRegions: page not found: " ++ (show r))
            Just pg  -> do dumpRgns pg


