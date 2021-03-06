module Translation.Base exposing (..)

import Parser exposing (TranslatedBlock(..))
import Either exposing (Either(..))
import AtLeastOneOf exposing (AtLeastOneOf)
import Helper
import Helper.Cont as Cont exposing ((<*>), (<<|))
import List.Nonempty as Nonempty exposing (Nonempty)


-- TYPES


type alias Word =
    String


type Collapsable a b
    = LoneLeaf b
    | Block (Block a b)


mapCollapsable : (a -> c) -> (b -> d) -> Collapsable a b -> Collapsable c d
mapCollapsable f g c =
    case c of
        LoneLeaf b ->
            LoneLeaf (g b)

        Block block ->
            Block (mapBlock f g block)


type Block a b
    = CursorBlock (CursorBlock a b)
    | ExpandedBlock a (AtLeastOneOf (Block a b) b)


mapBlock : (a -> c) -> (b -> d) -> Block a b -> Block c d
mapBlock f g block =
    case block of
        ExpandedBlock a bs ->
            ExpandedBlock (f a) (AtLeastOneOf.map (mapBlock f g) g bs)

        CursorBlock block ->
            CursorBlock (mapCursorBlock f g block)


getNodeBlock : Block a b -> a
getNodeBlock block =
    case block of
        ExpandedBlock a _ ->
            a

        CursorBlock cblock ->
            getNodeCursorBlock cblock


updateNodeBlock : (a -> a) -> Block a b -> Block a b
updateNodeBlock f block =
    case block of
        ExpandedBlock a bs ->
            ExpandedBlock (f a) bs

        CursorBlock cblock ->
            CursorBlock (updateNodeCursorBlock f cblock)


type CursorBlock a b
    = TerminalBlock a (Nonempty b)
    | CollapsedBlock a (AtLeastOneOf (CursorBlock a b) b)


getNodeCursorBlock : CursorBlock a b -> a
getNodeCursorBlock block =
    case block of
        TerminalBlock a _ ->
            a

        CollapsedBlock a _ ->
            a


updateNodeCursorBlock : (a -> a) -> CursorBlock a b -> CursorBlock a b
updateNodeCursorBlock f block =
    case block of
        TerminalBlock a bs ->
            TerminalBlock (f a) bs

        CollapsedBlock a bs ->
            CollapsedBlock (f a) bs


mapCursorBlock : (a -> c) -> (b -> d) -> CursorBlock a b -> CursorBlock c d
mapCursorBlock f g block =
    case block of
        TerminalBlock a bs ->
            TerminalBlock (f a) (Nonempty.map g bs)

        CollapsedBlock a bs ->
            CollapsedBlock (f a) (AtLeastOneOf.map (mapCursorBlock f g) g bs)


type Ctx a b
    = Top
    | Down a (List (Collapsable a b)) (List (Collapsable a b)) (Ctx a b)


mapCtx : (a -> c) -> (b -> d) -> Ctx a b -> Ctx c d
mapCtx f g ctx =
    case ctx of
        Top ->
            Top

        Down a before after parctx ->
            Down (f a)
                (List.map (mapCollapsable f g) before)
                (List.map (mapCollapsable f g) after)
                (mapCtx f g parctx)


type Zipper a b
    = Zipper (Collapsable a b) (Ctx a b)


type BlockZipper a b
    = BlockZipper (Block a b) (Ctx a b)


getNodeBlockZipper : BlockZipper a b -> a
getNodeBlockZipper (BlockZipper block ctx) =
    getNodeBlock block


updateNodeBlockZipper : (a -> a) -> BlockZipper a b -> BlockZipper a b
updateNodeBlockZipper f (BlockZipper block ctx) =
    BlockZipper (updateNodeBlock f block) ctx


type CursorZipper a b
    = CursorZipper (CursorBlock a b) (Ctx a b)


mapCursorZipper : (a -> c) -> (b -> d) -> CursorZipper a b -> CursorZipper c d
mapCursorZipper f g (CursorZipper block ctx) =
    CursorZipper (mapCursorBlock f g block) (mapCtx f g ctx)


getNodeCursorZipper : CursorZipper a b -> a
getNodeCursorZipper (CursorZipper block ctx) =
    getNodeCursorBlock block


updateNodeCursorZipper : (a -> a) -> CursorZipper a b -> CursorZipper a b
updateNodeCursorZipper f (CursorZipper block ctx) =
    CursorZipper (updateNodeCursorBlock f block) ctx


type LeafZipper a b
    = LeafZipper b (Ctx a b)


nodes : Collapsable a b -> List a
nodes =
    foldr
        (always [])
        identity
        identity
        (\a ->
            (::) a
                << List.concat
                << AtLeastOneOf.toList
                << AtLeastOneOf.map identity (always [])
        )
        (\a -> always [ a ])
        (\a ->
            (::) a
                << List.concat
                << AtLeastOneOf.toList
                << AtLeastOneOf.map identity (always [])
        )


{-| a ~ a
    b ~ b
    Collapsable ~ s
    Block ~ t
    CursorBlock ~ u
-}
foldr :
    -- LoneLeaf
    (b -> s)
    -- Block
    -> (t -> s)
       -- CursorBlock
    -> (u -> t)
       -- ExpandedBlock
    -> (a -> AtLeastOneOf t b -> t)
       -- TerminalBlock
    -> (a -> Nonempty b -> u)
       -- CollapsedBlock
    -> (a -> AtLeastOneOf u b -> u)
    -> Collapsable a b
    -> s
foldr loneWord block cursorBlock expandedBlock terminalBlock collapsedBlock col =
    case col of
        LoneLeaf w ->
            loneWord w

        Block blk ->
            let
                goBlock blk =
                    case blk of
                        CursorBlock cblk ->
                            let
                                goCursorBlock cblk =
                                    case cblk of
                                        TerminalBlock a bs ->
                                            terminalBlock a bs

                                        CollapsedBlock a bs ->
                                            collapsedBlock a
                                                (AtLeastOneOf.map
                                                    goCursorBlock
                                                    identity
                                                    bs
                                                )
                            in
                                cursorBlock <| goCursorBlock cblk

                        ExpandedBlock a bs ->
                            expandedBlock a
                                (AtLeastOneOf.map goBlock identity bs)
            in
                block <| goBlock blk


foldl :
    (b -> s)
    -> (t -> s)
    -> (u -> t)
    -> (a -> AtLeastOneOf t b -> t)
    -> (a -> Nonempty b -> u)
    -> (a -> AtLeastOneOf u b -> u)
    -> Collapsable a b
    -> s
foldl loneWord block cursorBlock expandedBlock terminalBlock collapsedBlock col =
    foldr (Cont.map loneWord)
        (Cont.map block)
        (Cont.map cursorBlock)
        (\a bs -> expandedBlock <<| a <*> AtLeastOneOf.traverseCont bs)
        (\a bs -> terminalBlock <<| a <*> Helper.nonemptyTraverseCont bs)
        (\a bs -> collapsedBlock <<| a <*> AtLeastOneOf.traverseCont bs)
        (mapCollapsable Cont.pure Cont.pure col)
        identity



-- FROM TRANSLATED BLOCKS


fullyExpanded : TranslatedBlock -> Collapsable String Word
fullyExpanded block =
    case block of
        L2Word w ->
            LoneLeaf w

        TranslatedBlock bs_ tr_ ->
            let
                fullyExpandedBlock ( bs, tr ) =
                    case
                        AtLeastOneOf.fromNonempty
                            (Nonempty.map translatedBlockToEither bs)
                    of
                        Right words ->
                            CursorBlock <| TerminalBlock tr words

                        Left z ->
                            ExpandedBlock tr
                                (AtLeastOneOf.map fullyExpandedBlock identity z)
            in
                Block <| fullyExpandedBlock ( bs_, tr_ )


fullyCollapsed : TranslatedBlock -> Collapsable String Word
fullyCollapsed block =
    case block of
        L2Word w ->
            LoneLeaf w

        TranslatedBlock bs tr ->
            let
                fullyCollapsedInner ( bs_, tr_ ) =
                    case
                        AtLeastOneOf.fromNonempty
                            (Nonempty.map translatedBlockToEither bs_)
                    of
                        Right words ->
                            TerminalBlock tr_ words

                        Left bs ->
                            CollapsedBlock tr_
                                (AtLeastOneOf.map
                                    fullyCollapsedInner
                                    identity
                                    bs
                                )
            in
                -- use result of terminal block instead
                Block <| CursorBlock <| fullyCollapsedInner ( bs, tr )


fullyCollapse : Collapsable a b -> Either (CursorBlock a b) b
fullyCollapse collapsable =
    case collapsable of
        LoneLeaf b ->
            Right b

        Block block ->
            let
                fullyCollapseBlock block =
                    case block of
                        ExpandedBlock a bs ->
                            CollapsedBlock a
                                (AtLeastOneOf.map
                                    fullyCollapseBlock
                                    identity
                                    bs
                                )

                        CursorBlock cblock ->
                            cblock
            in
                Left <| fullyCollapseBlock block



-- HELPER


translatedBlockToEither :
    TranslatedBlock
    -> Either ( Nonempty TranslatedBlock, String ) String
translatedBlockToEither b =
    case b of
        L2Word w ->
            Right w

        TranslatedBlock bs tr ->
            Left ( bs, tr )


fromCollapsable : Collapsable a b -> Either (Block a b) b
fromCollapsable collapsable =
    case collapsable of
        Block block ->
            Left block

        LoneLeaf w ->
            Right w
