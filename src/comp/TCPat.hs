module TCPat(tiPat, tiPats) where

import Control.Monad
import qualified Data.Map as M
--import Debug.Trace

import Util(elemBy, concatMapM)
import Id
import Position
import Error(internalError, EMsgs(..), ErrMsg(..))
import Pred
import Scheme
import Assump
import TIMonad
import TCMisc(unify, unifyFnFrom, unifyFnTo, mkVPred, niceTypes)
import PreIds(idPrimUnit, tupleIds, idComma, idPrimPair, idPrimFst, idPrimSnd)
import CSyntax
import CType(leftTyCon, getArrows, isTypeUnit)
import PFPrint

tiPat :: Type -> CPat -> TI ([VPred], [Assump], CPat)
tiPat td pat =
    do _ <- detectDuplicatePV emptyPVEnv pat
       tiPat' td pat

tiPat' :: Type -> CPat -> TI ([VPred], [Assump], CPat)

tiPat' td (CPCon comma [p1, p2]) | comma == idComma =
    let -- give position to the struct
        pair = setIdPosition (getIdPosition comma) idPrimPair
        -- give a user-source position to the field names
        mkField i p = (setIdPosition (getPosition p) i, p)
    in  tiPat' td (CPstruct pair [mkField idPrimFst p1, mkField idPrimSnd p2])

tiPat' td (CPCon c ps) = tiPCon td c (Right ps)

-- From deriving, so no pattern-checking required
-- (and not advisable, deriving assumes one argument)
tiPat' td (CPCon1 ti c pat) = tiPCon td c (Left (pat, tdc))
  where tdc = TCon (TyCon ti Nothing TIabstract)

tiPat' td pat@(CPstruct c ips) = do
--    trace ("tiPat " ++ ppReadable (pat,td)) $ return ()
    let err_handler :: EMsgs -> TI (Maybe a)
        err_handler es =
          if (all (\emsg -> case emsg of (_, EConstrAmb _ _) -> True; _ -> False) (errmsgs es))
          then errs "tiPat'" (errmsgs es)
          else return Nothing
    mti <- (findCons td c >>= \ (_, ti) -> return (Just ti)) `handle` err_handler
    case mti of
     -- Should we exempt struct patterns from checking here
     -- (instead of or in addition to checkConPats below)?
     Just ti -> tiPCon td c (Right [CPstruct (mkTCId ti c) ips])
     Nothing -> do
       find_res <- findTyCon c
       case find_res of
         tyc@(TyCon qc (Just k) ti) ->
           case ti of
             TIstruct _ fs -> do
                 let mkTS t KStar = return t
                     mkTS t (Kfun ka k) = do v <- newTVar "tiPat CPstruct" ka c; mkTS (TAp t v) k
                     mkTS _ (KVar v) = internalError ("TCPat.tiPat': KVar " ++ show v)
                     mkTS _ KNum = internalError ("TCPat.tiPat': KNum")
                 st <- mkTS (TCon tyc) k
                 _ <- unify pat st td
                 psasips <- mapM (tiPField qc fs td) ips
                 let (pss, ass, ips') = unzip3 psasips
                 return (concat pss, concat ass, CPstruct c ips')
             _ -> err (getPosition c, ENotStructId (pfpString c))
         _ -> internalError ("tiPat': findTyCon didn't return expected TyCon")

tiPat' td pat@(CPAny {}) = do
    return ([], [], pat)

tiPat' td pat@(CPVar i) = do
    return ([], [i :>: toScheme td], pat)

tiPat' td pat@(CPLit l) = internalError "TCPat.tiPat: CPLit"
tiPat' td pat@(CPMixedLit {}) = internalError "TCPat.tiPat: CPMixedLit"

tiPat' td (CPAs i p) = do
    (ps, as, pat') <- tiPat' td p
    return (ps, (i :>: toScheme td) : as, CPAs i pat')
tiPat' td (CPConTs _ _ _ _) = internalError "TCPat.tiPat': CPConTs"
tiPat' td (CPOper _) = internalError "TCPat.tiPat': CPOper"

-- Make sure that constructor patterns provide all their arguments
checkPCon :: Id -> Type -> [CPat] -> TI ()
-- Explicit struct patterns are allowed to be incomplete
checkPCon _ _ p@[CPstruct _ _] = return ()
checkPCon c t ps = do
  -- Calculate expected arguments from constructor type
  let (argTys, res) = getArrows t
      nargs = case argTys of
               [argTy] | isTypeUnit argTy -> 0
                       -- Multi-argument constructor patterns only work when the fields are anonymous.
                       | Just (TyCon _ _ (TIstruct (SDataCon _ False) fs)) <- leftTyCon argTy -> length fs
               _ -> 1
      npats = length ps
      con_pos = getPosition c
  when (npats /= nargs) $
    err (con_pos, EConPatArgs (pfpString c) (Just $ pfpString $ niceTypes res) nargs npats)

-- Takes an Either so we can special-case CPCon1 (generated by deriving)
-- (don't check the single pattern and use the supplied result type).
tiPCon :: Type -> Id -> (Either (CPat, Type) [CPat]) -> TI ([VPred], [Assump], CPat)
tiPCon td c args = do
    let tdc = either snd (const td) args
    (c' :>: sc, ti) <- findCons tdc c
    (qs :=> t, ts) <- freshInst "A" c sc

    _ <- either (const $ return ()) (checkPCon c t) args

    let con_pos = getIdPosition c
        unit = setIdPosition con_pos idPrimUnit
        mkField i p = (setIdPosition (getPosition p) i, p)
        pat = case args of
          Left (p,_) -> p
          Right []   -> CPstruct unit []
          Right [p]  -> p
          Right ps   -> CPstruct (mkTCId ti c) $ zipWith mkField tupleIds ps

    (tp,eq_ps) <- unifyFnFrom pat (CPCon c [pat]) t td
    (ps,as,pat')   <- tiPat' tp pat
    qs'            <- concatMapM (mkVPred (getPosition c)) qs
    return (eq_ps ++ qs' ++ ps, as, CPConTs ti c' ts [pat'])

tiPField :: Id -> [Id] -> Type -> (Id, CPat) -> TI ([VPred], [Assump], (Id, CPat))
tiPField si fs rt (i, p) =
    if not (elemBy qualEq i fs) then
        err (getPosition i, ENotField (pfpString si) (pfpString i))
    else do
        (i' :>: sc, _, _) <- findFields rt i
        (qs :=> t', _)   <- freshInst "B" i sc
        (t,eq_ps) <- unifyFnTo i p t' rt
        (ps, as, p')     <- tiPat' t p
        qs'              <- concatMapM (mkVPred (getPosition i)) qs
        return (eq_ps++ps++qs', as, (i', p'))

tiPats :: [Type] -> [CPat] -> TI ([VPred], [Assump], [CPat])
tiPats ts pats = do
    _ <- foldM detectDuplicatePV emptyPVEnv pats
    psasips <- mapM (uncurry tiPat') (zip ts pats)
    let (pss, ass, ips) = unzip3 psasips
    return (concat pss, concat ass, ips)

-- pattern variable environment
type PVEnv = M.Map Id Position

-- empty PVEnv to start with
emptyPVEnv :: PVEnv
emptyPVEnv = M.empty

-- detect duplicate pattern variables; fail typechecking if any found
--
-- this could actually be done before typechecking, but turns out to
-- be convenient there because both frontends can use it
detectDuplicatePV :: PVEnv -> CPat -> TI PVEnv
detectDuplicatePV env (CPVar var) =
    let pos = getIdPosition var
    in  case var `M.lookup` env of
          Nothing -> return (M.insert var pos env)
          Just pos' -> err (pos, EMultipleDecl (pfpString var) pos')
detectDuplicatePV env (CPAs var pat) = detectDuplicatePV env' pat
    where env' = M.insert var (getIdPosition var) env
detectDuplicatePV env (CPstruct _ fields) =
    foldM detectDuplicatePV env [pat | (name, pat) <- fields]
detectDuplicatePV env (CPCon _ pats) = foldM detectDuplicatePV env pats
detectDuplicatePV env (CPCon1 _ _ pat) = detectDuplicatePV env pat
detectDuplicatePV env (CPConTs _ _ _ pats) = foldM detectDuplicatePV env pats
detectDuplicatePV env (CPAny {}) = return env
detectDuplicatePV env (CPLit _) = return env
detectDuplicatePV env (CPMixedLit {}) = return env
detectDuplicatePV env (CPOper opPats) = foldM detectDuplicatePVOp env opPats
    where detectDuplicatePVOp env (CPRand pat) = detectDuplicatePV env pat
          detectDuplicatePVOp env (CPRator _ _) = return env
