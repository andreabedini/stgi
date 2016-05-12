{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}

-- | The STG language syntax tree, modeled after the description in the
-- 1992 paper
-- <http://research.microsoft.com/apps/pubs/default.aspx?id=67083 (link)>.
--
-- A 'Program' is typically created using functionality provided by the
-- "Stg.Parser" module, as opposed to manually combining the data types given
-- in this module.
--
-- For plenty of comparisons of STG language source and generated parse trees,
-- have a look at the "Stg.Parser.QuasiQuoter" module.
module Stg.Language (
    Program        (..),
    Binds          (..),
    LambdaForm     (..),
    prettyLambda,
    UpdateFlag     (..),
    Rec            (..),
    Expr           (..),
    Alts           (..),
    NonDefaultAlts (..),
    AlgebraicAlt   (..),
    PrimitiveAlt   (..),
    DefaultAlt     (..),
    Literal        (..),
    PrimOp         (..),
    Var            (..),
    Atom           (..),
    Constr         (..),
) where



import           Data.List.NonEmpty           (NonEmpty (..))
import qualified Data.List.NonEmpty           as NonEmpty
import           Data.Map                     (Map)
import qualified Data.Map                     as M
import           Data.Monoid                  hiding (Alt)
import           Data.Text                    (Text)
import qualified Data.Text                    as T
import           GHC.Exts
import           GHC.Generics
import           Language.Haskell.TH.Lift
import           Text.PrettyPrint.ANSI.Leijen hiding ((<>))

-- $setup
-- >>> :set -XQuasiQuotes
-- >>> import Stg.Parser



-- | An STG program consists of bindings.
newtype Program = Program Binds
    deriving (Eq, Ord, Show, Generic)

-- | Left-biased union of the contained bindings.
instance Monoid Program where
    mempty = Program mempty
    Program x `mappend` Program y = Program (x <> y)

-- | Bindings are collections of lambda forms, indexed over variables.
--
-- They exist at the top level, or as part of a let(rec) binding.
newtype Binds = Binds (Map Var LambdaForm)
    deriving (Eq, Ord, Generic)

instance Monoid Binds where
    mempty = Binds mempty
    Binds x `mappend` Binds y = Binds (x <> y)

instance Show Binds where
    show (Binds binds) = "(Binds " <> show (M.assocs binds) <> ")"

-- | A lambda form unifies free and bound variables associated with a function
-- body. The lambda body must not be of primitive type, as this would imply
-- the value is both boxed and unboxed.
--
-- >>> [stg| (x) \n (y, z) -> expr (x,z) |]
-- LambdaForm [Var "x"] NoUpdate [Var "y",Var "z"] (AppF (Var "expr") [AtomVar (Var "x"),AtomVar (Var "z")])
data LambdaForm = LambdaForm [Var] UpdateFlag [Var] Expr
    deriving (Eq, Ord, Show, Generic)

-- | The update flag distinguishes updateable from non-updateable lambda forms.
--
-- The former will be overwritten in-place when it is evaluated, allowing
-- the calculation of a thunk to be shared among multiple uses of the
-- same value.
data UpdateFlag = Update | NoUpdate
    deriving (Eq, Ord, Show, Generic, Enum, Bounded)

-- | Distinguishes @let@ from @letrec@.
data Rec = NonRecursive | Recursive
    deriving (Eq, Ord, Show, Generic, Enum, Bounded)

-- | An expression in the STG language.
data Expr =
      Let Rec Binds Expr    -- ^ Let expression @let(rec) ... in ...@
    | Case Expr Alts        -- ^ Case expression @case ... of ... x -> y@
    | AppF Var [Atom]       -- ^ Function application @f (x,y,z)@
    | AppC Constr [Atom]    -- ^ Constructor application @Maybe (a)@
    | AppP PrimOp Atom Atom -- ^ Primitive function application @+# 1# 2#@
    | Lit Literal           -- ^ Literal expression @1#@
    deriving (Eq, Ord, Show, Generic)

-- | List of possible alternatives in a 'Case' expression.
--
-- The list of alts has to be homogeneous. This is not ensured by the type
-- system, and should be handled by the parser instead.
data Alts = Alts NonDefaultAlts DefaultAlt
    deriving (Eq, Ord, Show, Generic)

data NonDefaultAlts =
      NoNonDefaultAlts
        -- ^ Used in 'case' statements that consist only of a default
        -- alternative. These can be useful to force or unpack values.

    | AlgebraicAlts (NonEmpty AlgebraicAlt)
        -- ^ Algebraic alternative, like @Cons (x,xs)@.

    | PrimitiveAlts (NonEmpty PrimitiveAlt)
        -- ^ Primitive alternative, like @1#@.
    deriving (Eq, Ord, Show, Generic)

-- | As in @True | False@
data AlgebraicAlt = AlgebraicAlt Constr [Var] Expr
    deriving (Eq, Ord, Show, Generic)

-- | As in @1, 2, 3@
data PrimitiveAlt = PrimitiveAlt Literal Expr
    deriving (Eq, Ord, Show, Generic)

-- | If no viable alternative is found in a pattern match, use a 'DefaultAlt'
-- as fallback.
data DefaultAlt =
       DefaultNotBound Expr
     | DefaultBound Var Expr
    deriving (Eq, Ord, Show, Generic)

-- | Literals are the basis of primitive operations.
newtype Literal = Literal Integer
    deriving (Eq, Ord, Show, Generic)

instance Num Literal where
    Literal x + Literal y = Literal (x + y)
    Literal x * Literal y = Literal (x * y)
    Literal x - Literal y = Literal (x - y)

    abs    (Literal i) = Literal (abs i)
    signum (Literal i) = Literal (abs i)
    negate (Literal i) = Literal (negate i)

    fromInteger = Literal . fromInteger

-- | Primitive operations.
data PrimOp =
    Add | Sub | Mul | Div | Mod | Eq | Lt | Leq | Gt | Geq | Neq
    deriving (Eq, Ord, Show, Generic, Bounded, Enum)

-- | Variable.
newtype Var = Var Text
    deriving (Eq, Ord, Show, Generic)

instance IsString Var where fromString = coerce . T.pack

-- | Smallest unit of data.
data Atom =
      AtomVar Var
    | AtomLit Literal
    deriving (Eq, Ord, Show, Generic)

-- | Constructors of algebraic data types.
newtype Constr = Constr Text
    deriving (Eq, Ord, Show, Generic)

instance IsString Constr where fromString = coerce . T.pack



--------------------------------------------------------------------------------
-- Lift instances
deriveLiftMany [ ''Program, ''Literal, ''LambdaForm , ''UpdateFlag, ''Rec
               , ''Expr, ''Alts, ''AlgebraicAlt, ''PrimitiveAlt, ''DefaultAlt
               , ''PrimOp, ''Atom ]

instance Lift NonDefaultAlts where
    lift NoNonDefaultAlts = [| NoNonDefaultAlts |]
    lift (AlgebraicAlts alts) =
        [| AlgebraicAlts (NonEmpty.fromList $(lift (toList alts))) |]
    lift (PrimitiveAlts alts) =
        [| PrimitiveAlts (NonEmpty.fromList $(lift (toList alts))) |]

instance Lift Binds where
    lift (Binds binds) = [| Binds (M.fromList $(lift (M.assocs binds))) |]

instance Lift Constr where
    lift (Constr con) = [| Constr (T.pack $(lift (T.unpack con))) |]

instance Lift Var where
    lift (Var var) = [| Var (T.pack $(lift (T.unpack var))) |]



--------------------------------------------------------------------------------
-- Pretty instances

instance Pretty Program where
    pretty (Program binds) = pretty binds

instance Pretty Binds where
    pretty (Binds bs) =
        (align . vsep . punctuate ";" . map prettyBinding . M.assocs) bs
      where
        prettyBinding (var, lambda) =
            pretty var <+> "=" <+> pretty lambda

-- | Prettyprint a 'LambdaForm', given prettyprinters for subcomponents.
--
-- Introduced so 'Stg.Machine.Types.Closure' can hijack it to display
-- the free value list differently.
prettyLambda
    :: (Doc -> Doc)        -- ^ Lambda head formatter, e.g. to colour @() \n ()@
    -> ([Var] -> Doc)      -- ^ Free variable list printer
    -> (UpdateFlag -> Doc) -- ^ Update flag printer
    -> ([Var] -> Doc)      -- ^ Bound variable list printer
    -> (Expr -> Doc)       -- ^ Body printer
    -> LambdaForm
    -> Doc
prettyLambda
    prettyLambdaHead
    prettyFreeList
    prettyUpd
    prettyBoundList
    prettyExpr
    (LambdaForm free upd bound expr)
  = hsep [ prettyLambdaHead (hsep
             [ prettyFreeList free
             , prettyUpd upd
             , prettyBoundList bound ])
         , "->"
         , prettyExpr expr ]

instance Pretty LambdaForm where
    pretty = prettyLambda id prettyList pretty prettyList pretty

instance Pretty UpdateFlag where
    pretty = \case
        Update   -> "\\u"
        NoUpdate -> "\\n"

instance Pretty Rec where
    pretty = \case
        NonRecursive -> ""
        Recursive    -> "rec"

instance Pretty Expr where
    pretty = \case
        Let rec binds expr -> (align . vsep)
            [ "let" <> pretty rec <+> (case rec of
                Recursive -> hardline <> indent 4 (pretty binds)
                NonRecursive -> pretty binds)
            , "in" <+> pretty expr ]
        Case expr alts -> vsep [ "case" <+> pretty expr <+> "of"
                               , indent 4 (align (pretty alts)) ]
        AppF var args -> pretty var <+> prettyList args
        AppC con args -> pretty con <+> prettyList args
        AppP op arg1 arg2 -> pretty op <+> pretty arg1 <+> pretty arg2
        Lit lit -> pretty lit

instance Pretty Alts where
    pretty (Alts NoNonDefaultAlts def) = pretty def
    pretty (Alts (AlgebraicAlts alts) def) =
        (align . vsep . punctuate ";") (map pretty (toList alts) ++ [pretty def])
    pretty (Alts (PrimitiveAlts alts) def) =
        (align . vsep . punctuate ";") (map pretty (toList alts) ++ [pretty def])

instance Pretty AlgebraicAlt where
    pretty (AlgebraicAlt con args expr) =
        pretty con <+> prettyList args <+> "->" <+> pretty expr

instance Pretty PrimitiveAlt where
    pretty (PrimitiveAlt lit expr) =
        pretty lit <+> "->" <+> pretty expr

instance Pretty DefaultAlt where
    pretty = \case
        DefaultNotBound expr  -> "default" <+> "->" <+> pretty expr
        DefaultBound var expr -> pretty var <+> "->" <+> pretty expr

instance Pretty Literal where
    pretty (Literal i) = integer i <> "#"

instance Pretty PrimOp where
    pretty = \case
        Add -> "+#"
        Sub -> "-#"
        Mul -> "*#"
        Div -> "/#"
        Mod -> "%#"
        Eq  -> "==#"
        Lt  -> "<#"
        Leq -> "<=#"
        Gt  -> ">#"
        Geq -> ">=#"
        Neq -> "/=#"

instance Pretty Var where
    pretty (Var name) = string (T.unpack name)
    prettyList = parens . align . hcat . punctuate "," . map pretty

instance Pretty Atom where
    pretty = \case
        AtomVar var -> pretty var
        AtomLit lit -> pretty lit
    prettyList = parens . align . hcat . punctuate "," . map pretty

instance Pretty Constr where
    pretty (Constr name) = string (T.unpack name)
