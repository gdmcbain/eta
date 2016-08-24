{-# LANGUAGE OverloadedStrings #-}
module GHCVM.CodeGen.Prim where

import GHCVM.Main.DynFlags
import GHCVM.Types.TyCon
import GHCVM.Types.Type
import GHCVM.StgSyn.StgSyn
import GHCVM.Prelude.PrimOp
import GHCVM.Utils.Panic
import GHCVM.Utils.FastString

import Codec.JVM

import GHCVM.CodeGen.ArgRep
import GHCVM.CodeGen.Monad
import GHCVM.CodeGen.Foreign
import GHCVM.CodeGen.Env
import GHCVM.CodeGen.Layout
import GHCVM.CodeGen.Types
import GHCVM.CodeGen.Utils
import GHCVM.CodeGen.Rts
import GHCVM.CodeGen.Name

import GHCVM.Debug
import GHCVM.Util

import Data.Monoid ((<>))
import Data.Foldable (fold)
import Data.Maybe (fromJust, isJust)
import Data.Text (Text)
import Data.List (stripPrefix)

cgOpApp :: StgOp
        -> [StgArg]
        -> Type
        -> CodeGen ()
cgOpApp (StgFCallOp fcall _) args resType = cgForeignCall fcall args resType
-- TODO: Is this primop necessary like in GHC?
cgOpApp (StgPrimOp TagToEnumOp) args@[arg] resType = do
  dflags <- getDynFlags
  codes <- getNonVoidArgCodes args
  let code = case codes of
        [code'] -> code'
        _ -> panic "TagToEnumOp had void arg"
  emitReturn [mkLocDirect True $ tagToClosure dflags tyCon code]
  where tyCon = tyConAppTyCon resType

cgOpApp (StgPrimOp primOp) args resType = do
    dflags <- getDynFlags
    argCodes <- getNonVoidArgFtCodes args
    case shouldInlinePrimOp dflags primOp argCodes of
      Left primOpLoc -> do
        args' <- getFtsLoadCode args
        emit $ mkCallExit True args'
            <> mkRtsFunCall primOpLoc
      -- TODO: Optimize: Remove the intermediate temp locations
      --       and allow direct code locations
      Right codes'
        | ReturnsPrim VoidRep <- resultInfo
        -> --f [] >> emitReturn []
          emitReturn []
        | ReturnsPrim rep <- resultInfo
              -- res <- newTemp rep'
              -- f [res]
              -- emitReturn [res]
        -> do -- Assumes Returns Prim is of Non-closure type
              codes <- codes'
              emitReturn [ mkLocDirect False (primRepFieldType rep, head codes) ]
        | ReturnsAlg tyCon <- resultInfo, isUnboxedTupleTyCon tyCon
        -> do -- locs <- newUnboxedTupleLocs resType
              -- f locs
              codes <- codes'
              let reps = getUnboxedResultReps resType
              emitReturn
                . map (\(rep, code) ->
                         mkLocDirect (isGcPtrRep rep) (primRepFieldType rep, code))
                $ zip reps codes
        | otherwise -> panic "cgPrimOp"
        where resultInfo = getPrimOpResultInfo primOp

-- NOTE: The GHCVM specific primops will get handled here
-- @inline, @rts, @static
cgOpApp (StgPrimCallOp (PrimCall label _)) args resType = do
  case words labelString of
    ("@inline":name:_) -> do
      argFtCodes <- getNonVoidArgFtCodes args
      emitReturn [mkLocDirect False (fromJust resFt, inlinePrimCall name argFtCodes)]
    ("@rts":name:_) -> do
      locs  <- newUnboxedTupleLocs resType
      args' <- getFtsLoadCode args
      let (clsName, methodName) = labelToMethod name
      emit $ mkCallExit True args'
          <> loadContext
          <> invokestatic (mkMethodRef clsName methodName [contextType] void)
          <> mkReturnEntry locs
      -- TODO: Handle result
    ("@static":"@field":name:_) ->
      let (clsName, fieldName) = labelToMethod name
      in genSequel $ getstatic $ mkFieldRef clsName fieldName (fromJust resFt)
    ("@static":name:_) -> primJava name invokestatic
    (name:_) -> primJava name invokevirtual
  where labelString = unpackFS label
        resRep = typePrimRep resType
        resFt = primRepFieldType_maybe resRep
        primJava name instr = do
          argsFtCodes <- getNonVoidArgFtCodes args
          let (argFts, callArgs) = unzip argsFtCodes
              (clsName, methodName) = labelToMethod name
              callTarget = fold callArgs
                        <> instr (mkMethodRef clsName methodName argFts resFt)
          genSequel callTarget
        genSequel callTarget = do
          sequel <- getSequel
          case sequel of
            AssignTo targetLocs ->
              if isJust resFt then
                emitAssign (head targetLocs) callTarget
              else
                emit $ callTarget
            _ -> do
              resLocs <- if isJust resFt then do
                           resLoc <- newTemp (isGcPtrRep resRep) (fromJust resFt)
                           emitAssign resLoc callTarget
                           return [resLoc]
                         else
                           return []
              emitReturn resLocs

inlinePrimCall :: String -> [(FieldType, Code)] -> Code
inlinePrimCall name = error $ "inlinePrimCall: unimplemented = " ++ name

shouldInlinePrimOp :: DynFlags -> PrimOp -> [(FieldType, Code)] -> Either (Text, Text) (CodeGen [Code])
shouldInlinePrimOp dflags ObjectArrayAtOp args = Right $
  let (_, codes) = unzip args
      elemFt = getArrayElemFt (fst (head args))
  in return [normalOp (gaload elemFt) codes]

shouldInlinePrimOp dflags ObjectArraySetOp args = Right $
  let (_, codes) = unzip args
      elemFt = getArrayElemFt (fst (head args))
  in return [normalOp (gastore elemFt) codes]

shouldInlinePrimOp dflags op args = shouldInlinePrimOp' dflags op $ snd (unzip args)

shouldInlinePrimOp' :: DynFlags -> PrimOp -> [Code] -> Either (Text, Text) (CodeGen [Code])
-- TODO: Inline array operations conditionally
shouldInlinePrimOp' dflags NewArrayOp args = Right $ return
  [
    new stgArrayType
 <> dup stgArrayType
 <> fold args
 <> invokespecial (mkMethodRef stgArray "<init>" [jint, closureType] void)
  ]

shouldInlinePrimOp' dflags UnsafeThawArrayOp args = Right $ return [fold args]

shouldInlinePrimOp' dflags primOp args
  | primOpOutOfLine primOp = Left $ mkRtsPrimOp primOp
  | otherwise = Right $ emitPrimOp primOp args

mkRtsPrimOp :: PrimOp -> (Text, Text)
mkRtsPrimOp RaiseOp           = (stgExceptionGroup, "raise")
mkRtsPrimOp primop = pprPanic "mkRtsPrimOp: unimplemented!" (ppr primop)

cgPrimOp   :: PrimOp            -- the op
           -> [StgArg]          -- arguments
           -> CodeGen [Code]
cgPrimOp op args = do
  argExprs <- getNonVoidArgCodes args
  emitPrimOp op argExprs

-- emitPrimOp :: [CgLoc]        -- where to put the results
--            -> PrimOp         -- the op
--            -> [Code]         -- arguments
--            -> CodeGen ()
emitPrimOp :: PrimOp -> [Code] -> CodeGen [Code]
emitPrimOp IndexOffAddrOp_Char [arg1, arg2]
  = return [ arg1
          <> arg2
          <> invokevirtual (mkMethodRef jstringC "charAt"
                                        [jint] (ret jchar))]
          -- TODO: You may have to cast to int or do some extra stuff here
          --       or maybe instead reference the direct byte array
emitPrimOp DataToTagOp [arg] = return [getTagMethod arg]

emitPrimOp IntQuotRemOp args = do
  codes1 <- emitPrimOp IntQuotOp args
  codes2 <- emitPrimOp IntRemOp args
  return $ codes1 ++ codes2

emitPrimOp WordQuotRemOp args = do
  codes1 <- emitPrimOp WordQuotOp args
  codes2 <- emitPrimOp WordRemOp args
  return $ codes1 ++ codes2

emitPrimOp IntAddCOp [arg1, arg2] = do
  tmp <- newTemp False jint
  emit $ storeLoc tmp (arg1 <> arg2 <> iadd)
  let sum = loadLoc tmp
  return $ [ sum
           , (arg1 <> sum <> ixor)
          <> (arg2 <> sum <> ixor)
          <> iand
          <> inot
           ]

emitPrimOp IntSubCOp [arg1, arg2] = do
  tmp <- newTemp False jint
  emit $ storeLoc tmp (arg1 <> arg2 <> isub)
  let diff = loadLoc tmp
  return $ [ diff
           , (arg1 <> arg2 <> ixor)
          <> (arg1 <> diff <> ixor)
          <> iand
          <> inot
           ]

emitPrimOp IntMulMayOfloOp [arg1, arg2] = do
  tmp <- newTemp False jint
  emit $ storeLoc tmp ( (arg1 <> gconv jint jlong)
                     <> (arg2 <> gconv jint jlong)
                     <> lmul )
  let mul = loadLoc tmp
  return $ [ mul
          <> gconv jlong jint
          <> gconv jint  jlong
          <> mul
          <> lcmp
           ]

emitPrimOp op [arg]
  | nopOp op = return [arg]
emitPrimOp op args
  | Just execute <- simpleOp op
  = return [execute args]
emitPrimOp op _ = pprPanic "emitPrimOp: unimplemented" (ppr op)

nopOp :: PrimOp -> Bool
nopOp Int2WordOp   = True
nopOp Word2IntOp   = True
nopOp OrdOp        = True
nopOp ChrOp        = True
nopOp Int642Word64 = True
nopOp Word642Int64 = True
nopOp ChrOp        = True
nopOp _            = False

normalOp :: Code -> [Code] -> Code
normalOp code = (<> code) . fold

idOp :: [Code] -> Code
idOp = normalOp mempty

intCompOp :: (Code -> Code -> Code) -> [Code] -> Code
intCompOp op args = flip normalOp args $ op (iconst jint 1) (iconst jint 0)

simpleOp :: PrimOp -> Maybe ([Code] -> Code)

-- Array# & MutableArray# ops
simpleOp UnsafeFreezeArrayOp  = Just idOp
simpleOp SameMutableArrayOp = Just $ intCompOp if_acmpeq
simpleOp SizeofArrayOp = Just $
  normalOp $ invokevirtual $ mkMethodRef stgArray "size" [] (ret jint)
simpleOp SizeofMutableArrayOp = Just $
  normalOp $ invokevirtual $ mkMethodRef stgArray "size" [] (ret jint)
simpleOp WriteArrayOp = Just $
  normalOp $ invokevirtual
    $ mkMethodRef stgArray "set" [jint, closureType] void
simpleOp ReadArrayOp = Just $
  normalOp $ invokevirtual
    $ mkMethodRef stgArray "get" [jint] (ret closureType)
simpleOp IndexArrayOp = Just $
  normalOp $ invokevirtual
    $ mkMethodRef stgArray "get" [jint] (ret closureType)
-- Int# ops
simpleOp IntAddOp = Just $ normalOp iadd
simpleOp IntSubOp = Just $ normalOp isub
simpleOp IntMulOp = Just $ normalOp imul
simpleOp IntQuotOp = Just $ normalOp idiv
simpleOp IntRemOp = Just $ normalOp irem

simpleOp AndIOp = Just $ normalOp iand
simpleOp OrIOp = Just $ normalOp ior
simpleOp XorIOp = Just $ normalOp ixor
simpleOp NotIOp = Just $ normalOp inot
simpleOp ISllOp = Just $ normalOp ishl
simpleOp ISraOp = Just $ normalOp ishr
simpleOp ISrlOp = Just $ normalOp iushr

simpleOp IntNegOp = Just $ normalOp ineg
simpleOp IntEqOp = Just $ intCompOp if_icmpeq
simpleOp IntNeOp = Just $ intCompOp if_icmpne
simpleOp IntLeOp = Just $ intCompOp if_icmple
simpleOp IntLtOp = Just $ intCompOp if_icmplt
simpleOp IntGeOp = Just $ intCompOp if_icmpge
simpleOp IntGtOp = Just $ intCompOp if_icmpgt

-- Word# ops
-- TODO: Take a look at compareUnsigned in JDK 8
--       and see if that's more efficient
simpleOp WordEqOp   = Just $ intCompOp if_icmpeq
simpleOp WordNeOp   = Just $ intCompOp if_icmpeq
simpleOp WordAddOp  = Just $ normalOp iadd
simpleOp WordSubOp  = Just $ normalOp isub
simpleOp WordMulOp  = Just $ normalOp imul
simpleOp WordQuotOp = Just $ unsignedOp ldiv
simpleOp WordRemOp  = Just $ unsignedOp lrem
simpleOp WordGtOp   = Just $ unsignedCmp ifgt
simpleOp WordGeOp   = Just $ unsignedCmp ifge
simpleOp WordLeOp   = Just $ unsignedCmp ifle
simpleOp WordLtOp   = Just $ unsignedCmp iflt
--Verify true for unsigned operations
simpleOp AndOp = Just $ normalOp iand
simpleOp OrOp = Just $ normalOp ior
simpleOp XorOp = Just $ normalOp ixor
simpleOp NotOp = Just $ normalOp inot
simpleOp SllOp = Just $ normalOp ishl
simpleOp SrlOp = Just $ normalOp iushr

-- Char# ops
simpleOp CharEqOp = Just $ intCompOp if_icmpeq
simpleOp CharNeOp = Just $ intCompOp if_icmpne
simpleOp CharGtOp = Just $ unsignedCmp ifgt
simpleOp CharGeOp = Just $ unsignedCmp ifge
simpleOp CharLeOp = Just $ unsignedCmp ifle
simpleOp CharLtOp = Just $ unsignedCmp iflt

-- Double# ops
simpleOp DoubleEqOp = Just $ typedCmp jdouble ifeq
simpleOp DoubleNeOp = Just $ typedCmp jdouble ifne
simpleOp DoubleGeOp = Just $ typedCmp jdouble ifge
simpleOp DoubleLeOp = Just $ typedCmp jdouble ifle
simpleOp DoubleGtOp = Just $ typedCmp jdouble ifgt
simpleOp DoubleLtOp = Just $ typedCmp jdouble iflt

simpleOp DoubleAddOp = Just $ normalOp dadd
simpleOp DoubleSubOp = Just $ normalOp dsub
simpleOp DoubleMulOp = Just $ normalOp dmul
simpleOp DoubleDivOp = Just $ normalOp ddiv
simpleOp DoubleNegOp = Just $ normalOp dneg

-- Float# ops
simpleOp FloatEqOp = Just $ typedCmp jfloat ifeq
simpleOp FloatNeOp = Just $ typedCmp jfloat ifne
simpleOp FloatGeOp = Just $ typedCmp jfloat ifge
simpleOp FloatLeOp = Just $ typedCmp jfloat ifle
simpleOp FloatGtOp = Just $ typedCmp jfloat ifgt
simpleOp FloatLtOp = Just $ typedCmp jfloat iflt

simpleOp FloatAddOp = Just $ normalOp fadd
simpleOp FloatSubOp = Just $ normalOp fsub
simpleOp FloatMulOp = Just $ normalOp fmul
simpleOp FloatDivOp = Just $ normalOp fdiv
simpleOp FloatNegOp = Just $ normalOp fneg

-- Conversions
simpleOp Int2DoubleOp   = Just $ normalOp $ gconv jint    jdouble
simpleOp Double2IntOp   = Just $ normalOp $ gconv jdouble jint
simpleOp Int2FloatOp    = Just $ normalOp $ gconv jint    jfloat
simpleOp Float2IntOp    = Just $ normalOp $ gconv jfloat  jint
simpleOp Float2DoubleOp = Just $ normalOp $ gconv jfloat  jdouble
simpleOp Double2FloatOp = Just $ normalOp $ gconv jdouble jfloat

simpleOp Word64Eq = Just $ typedCmp jlong ifeq
simpleOp Word64Ne = Just $ typedCmp jlong ifne
simpleOp Word64Lt = Just $ unsignedLongCmp iflt
simpleOp Word64Le = Just $ unsignedLongCmp ifle
simpleOp Word64Gt = Just $ unsignedLongCmp ifgt
simpleOp Word64Ge = Just $ unsignedLongCmp ifge
simpleOp Word64Quot = Just $
  normalOp $ invokestatic $ mkMethodRef rtsUnsigned "divideUnsigned" [jlong, jlong] (ret jlong)
simpleOp Word64Rem = Just $
  normalOp $ invokestatic $ mkMethodRef rtsUnsigned "remainderUnsigned" [jlong, jlong] (ret jlong)
simpleOp Word64And = Just $ normalOp land
simpleOp Word64Or = Just $ normalOp lor
simpleOp Word64Xor = Just $ normalOp lxor
simpleOp Word64Not = Just $ normalOp lnot
simpleOp Word64SllOp = Just $ normalOp lshl
simpleOp Word64SrlOp = Just $ normalOp lushr
simpleOp Int64Eq = Just $ typedCmp jlong ifeq
simpleOp Int64Ne = Just $ typedCmp jlong ifne
simpleOp Int64Lt = Just $ typedCmp jlong iflt
simpleOp Int64Le = Just $ typedCmp jlong ifle
simpleOp Int64Gt = Just $ typedCmp jlong ifgt
simpleOp Int64Ge = Just $ typedCmp jlong ifge
simpleOp Int64Quot = Just $ normalOp ldiv
simpleOp Int64Rem = Just $ normalOp lrem
simpleOp Int64Add = Just $ normalOp ladd
simpleOp Int64Sub = Just $ normalOp lsub
simpleOp Int64Mul = Just $ normalOp lmul
simpleOp Int64Neg = Just $ normalOp lneg
simpleOp Int64SllOp = Just $ normalOp lshl
simpleOp Int64SraOp = Just $ normalOp lshr
simpleOp Int64SrlOp = Just $ normalOp lushr
simpleOp Int2Int64 = Just $ normalOp $ gconv jint  jlong
simpleOp Int642Int = Just $ normalOp $ gconv jlong jint
simpleOp Word2Word64 = Just $ unsignedExtend . head
-- TODO: Right conversion?
simpleOp Word64ToWord = Just $ normalOp $ gconv jlong jint
simpleOp DecodeDoubleInteger = Just $ normalOp $ gconv jlong jint

simpleOp _ = Nothing

unsignedOp :: Code -> [Code] -> Code
unsignedOp op [arg1, arg2]
  = unsignedExtend arg1
 <> unsignedExtend arg2
 <> op
 <> gconv jlong jint

typedCmp :: FieldType -> (Code -> Code -> Code) -> [Code] -> Code
typedCmp ft ifop [arg1, arg2]
  = gcmp ft arg1 arg2
 <> ifop (iconst jint 1) (iconst jint 0)

unsignedCmp :: (Code -> Code -> Code) -> [Code] -> Code
unsignedCmp ifop args
  = typedCmp jlong ifop $ map unsignedExtend args

unsignedExtend :: Code -> Code
unsignedExtend i = i <> gconv jint jlong <> lconst 0xFFFFFFFF <> land

lONG_MIN_VALUE :: Code
lONG_MIN_VALUE = lconst 0x8000000000000000

unsignedLongCmp :: (Code -> Code -> Code) -> [Code] -> Code
unsignedLongCmp ifop args
  = typedCmp jlong ifop $ map addMin args
  where addMin x = x <> lONG_MIN_VALUE <> iadd
