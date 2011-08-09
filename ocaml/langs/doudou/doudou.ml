(* for parsing *)
open Parser
(* for pretty printing *)
open Pprinter

open Printf


(*********************************)
(* Definitions of data structure *)
(*********************************)

type name = string

type op = Nofix
	  | Prefix of int
	  | Infix of int * associativity
	  | Postfix of int

type symbol = | Name of name
	      | Symbol of name * op

type index = int

type nature = Explicit
	      | Implicit

class virtual ['a] tObj =
object 
  method uuid: int = 0
  method virtual get_name: string
  method virtual get_type: 'a
  method virtual pprint: unit -> token
  method virtual apply: ('a * nature) list -> 'a
end

type term = Type
	    | Cste of symbol
	    | Obj of term tObj

	    (* the Left name is only valid after parsing, and removed by typecheck*)
	    | TVar of index
		
	    (* these constructors are only valide after parsing, and removed by typechecking *)
	    | AVar
	    | TName of symbol

	    | App of term * (term * nature) list
	    | Impl of (symbol * term * nature) * term
	    | DestructWith of equation list

	    | TyAnnotation of term * term
	    | SrcInfo of pos * term

and equation = (pattern * nature) * term

and pattern = PType
	      | PVar of name * term
	      | PAVar of term
	      | PCste of symbol
	      | PAlias of name * pattern * term
	      | PApp of symbol * (pattern * nature) list * term

(* context of a term *)
(* N.B.: all terms are of the level in which they appear *)
type frame = {
  (* the symbol of the frame *)
  symbol : symbol;
  (* its type *)
  ty: term;

  (* its value: most stupid one: itself *)
  value: term;
    
  (* the free variables 
     - the index (redundant information put for sake of optimization)
     - the type of the free variable
     - its corresponding value (by unification)
  *)
  fvs: (index * term * term) list;

  (* the stacks *)
  termstack: term list;
  naturestack: nature list;
  equationstack: equation list;
  patternstack: pattern list;
  
}

let empty_frame = {
  symbol = Symbol ("_", Nofix);
  ty = Type;
  value = TVar 0;
  fvs = [];
  termstack = [];
  naturestack = [];
  equationstack = [];
  patternstack = [];
}

type context = frame list

(* the context must a least have one frame, for pushing/poping stack elements *)
let empty_context = empty_frame::[]
	   
(* definitions *)
type defs = {
  (* here we store all id in a string *)
  (* id -> (symbol * type * value) *)
  store : (string, (symbol * term * term option)) Hashtbl.t;
  hist : symbol list;
}

let empty_defs = { store = Hashtbl.create 30; hist = [] }

type doudou_error = NegativeIndexBVar of index
		    | Unshiftable_term of term * int * int

		    | ErrorPosPair of pos option * pos option * doudou_error
		    | ErrorPos of pos * doudou_error

		    | UnknownCste of symbol
		    | UnknownBVar of index * context
		    | UnknownFVar of index * context

		    | UnknownUnification of context * term * term
		    | NoUnification of context * term * term

		    | NoMatchingPattern of context * pattern * term

		    | PoppingNonEmptyFrame of frame

		    | CannotInfer of context * term * doudou_error
		    | CannotTypeCheck of context * term * term * term * doudou_error

exception DoudouException of doudou_error

(********************************************)
(* example of source that should be process *)
(********************************************)

let example = "
Bool :: Type
True :: Bool
False :: Bool

(||) :: Bool -> Bool -> Bool
(&&) :: Bool -> Bool -> Bool

True || _ := True
_ || True := True
False || False := False

False && _ := False
_ && False := False
True && True := True

List :: Type -> Type
[[]] :: {A :: Type} -> List A
(:) :: {A :: Type} -> A -> List A -> List A

String :: Type

plusType :: Type -> Type -> Type
(+) :: {A B :: Type} -> A -> B -> plusType A B

multType :: Type -> Type -> Type
(*) :: {A B :: Type} -> A -> B -> multType A B

plusType Bool Bool := Bool
(+) {Bool} {Bool} := (||)

multType Bool Bool := Bool
(+) {Bool} {Bool} := (&&)

String :: Type

List :: Type -> Type
[[]] :: {A :: Type} -> List A
(:) :: {A :: Type} -> A -> List A -> List A

(@) :: {A :: Type} -> List A -> List A
[] @ l := l
l @ [] := l
(hd:tl) @ l := hd:(tl @ [])

map :: {A B :: Type} -> (A -> B) -> List A -> List B
map f [] := []
map f (hd:tl) := (f hd):(map f tl)

plusType (List A) (List A) := List a
(+) {List A} {List A} := (@)

multType Type Type := Type
(,) :: {A B :: Type} -> A -> B -> A * B

multType (List A) (List B) := List (List (A * B))

_ * [] := []
[] * _ := []
(hd1:tl1) * l := (map ( x := (x, hd1)) l) : (tl1 * l)

foldl :: {A B :: Type} -> (B -> A -> B) -> B -> List A -> B
foldl f acc [] := acc
foldl f acc (hd:tl) := foldl f (f acc hd) tl

foldr :: {A B :: Type} -> (A -> B -> B) -> List A -> B -> B
foldr f [] acc := acc
foldr f (hd:tl) acc := f hd (foldr f tl acc)

Nat :: Type
O :: Nat
S :: Nat -> Nat

T :: Type -> Type -> Nat -> Type
T _ B O := B
T A B (S n) := A -> T A B n

depfold :: {A B :: Type} -> (f:: B -> A -> B) -> B -> (n :: Nat) -> T A B n
depfold f acc O := acc
depfold f acc (S n) := (x := depfold f (f acc x) n)

NatPlus :: Nat -> Nat -> Nat 
NatPlus O x := x
NatPlus x O := x
NatPlus (S x) y := S (NatPlus x y)

plusType Nat Nat := Nat
(+) {Nat] {Nat} := NatPlus

depfold {Nat} (+) O (S (S 0)) :?: 
(* :?: Nat -> Nat -> Nat *)
"



(******************)
(*      misc      *)
(******************)

(* take and drop as in haskell *)
let rec take (n: int) (l: 'a list) :'a list =
  match n with
    | 0 -> []
    | i when i < 0 -> raise (Invalid_argument "take")
    | _ -> 
      match l with
	| [] -> []
	| hd::tl -> hd::take (n-1) tl

let rec drop (n: int) (l: 'a list) :'a list =
  match n with
    | 0 -> l
    | i when i < 0 -> raise (Invalid_argument "drop")
    | _ -> 
      match l with
	| [] -> []
	| hd::tl -> drop (n-1) tl


(* some traverse fold without the reverse *)
let mapacc (f: 'b -> 'a -> ('c * 'b)) (acc: 'b) (l: 'a list) : 'c list * 'b =
  let acc = ref acc in
  (List.map (fun hd -> let (hd, acc') = f !acc hd in
		       acc := acc';
		       hd) l, !acc)

type ('a, 'b) either = Left of 'a
		       | Right of 'b
;;

(* a fold that might stop before the whole traversal *)
let rec fold_stop (f: 'b -> 'a -> ('b, 'c) either) (acc: 'b) (l: 'a list) : ('b, 'c) either =
  match l with
    | [] -> Left acc
    | hd::tl ->
      match f acc hd with
	| Left acc -> fold_stop f acc tl
	| Right res -> Right res

(* assert that pos1 contains pos2 *)
let pos_in (pos1: pos) (pos2: pos) : bool =
  let ((begin_line1, begin_col1), (end_line1, end_col1)) = pos1 in
  let ((begin_line2, begin_col2), (end_line2, end_col2)) = pos2 in
  (* the start of pos2 must be equal or after the start of pos1 *)
  ((begin_line2 > begin_line1) || (begin_line1 = begin_line2 && begin_col2 >= begin_col1))
  (* and the end of pos2 must be equal or before the end of pos 1*)
  && ((end_line2 < end_line1) || (end_line1 = end_line2 && end_col2 <= end_col1))

(* computation of free variable in a term *)
module IndexSet = Set.Make(
  struct
    type t = int
    let compare x y = compare x y
  end
);;

let rec fv_term (te: term) : IndexSet.t =
  match te with
    | Type | Cste _ | Obj _ -> IndexSet.empty
    | TVar i when i >= 0 -> IndexSet.empty
    | TVar i when i < 0 -> IndexSet.singleton i
    | AVar -> raise (Failure "fv_term catastrophic: AVar")
    | TName _ -> raise (Failure "fv_term catastrophic: TName")
    | App (te, args) ->
      List.fold_left (fun acc (te, _) -> IndexSet.union acc (fv_term te)) (fv_term te) args
    | Impl ((s, ty, n), te) ->
      IndexSet.union (fv_term ty) (fv_term te)
    | DestructWith eqs ->
      List.fold_left (fun acc eq -> IndexSet.union acc (fv_equation eq)) IndexSet.empty eqs
    | TyAnnotation (te, ty) -> IndexSet.union (fv_term ty) (fv_term te)
    | SrcInfo (pos, term) -> (fv_term te)

and fv_equation (eq: equation) : IndexSet.t = 
  let (p, _), te = eq in
  IndexSet.union (fv_pattern p) (fv_term te)
and fv_pattern (p: pattern) : IndexSet.t =
  match p with
    | PType | PCste _ -> IndexSet.empty
    | PVar (n, ty) -> fv_term ty
    | PAVar ty -> fv_term ty
    | PAlias (n, p, ty) -> IndexSet.union (fv_term ty) (fv_pattern p)
    | PApp (s, args, ty) ->
      List.fold_left (fun acc (p, _) -> IndexSet.union acc (fv_pattern p)) (fv_term ty) args


(* function like map, but that can skip elements *)
let rec skipmap (f: 'a -> 'b option) (l: 'a list) : 'b list =
  match l with
    | [] -> []
    | hd::tl -> 
      match f hd with
	| None -> skipmap f tl
	| Some hd -> hd::(skipmap f tl)

(* function that map symbol into string *)
let symbol2string (s: symbol) =
  match s with
    | Name n -> n
    | Symbol (n, o) ->
      let (pre, post) = 
	match o with
	  | Nofix -> "", ""
	  | Prefix _ -> "[", ")"
	  | Infix _ -> "(", ")"
	  | Postfix _ -> "(", "]"
      in
      String.concat "" [pre; n; post]

(* get a bound variable frame *)
let get_bvar_frame (ctxt: context) (i: index) : frame =
  try 
    List.nth ctxt i
  with
    | Failure _ -> raise (DoudouException (UnknownBVar (i, ctxt)))
    | Invalid_argument _ -> raise (DoudouException (NegativeIndexBVar i))

(*
  the priority of operators
  the greater, the more strongly binding
  Nofix have 0
*)
let op_priority (o: op) : int =
  match o with
    | Nofix -> 0
    | Prefix i -> i
    | Infix (i, _) -> i
    | Postfix i -> i

(* returns only the elements that are explicit *)
let filter_explicit (l: ('a * nature) list) : 'a list =
  List.map fst (List.filter (fun (_, n) -> n = Explicit) l)
    

(* this function take a term te1 and
   return a list of pattern ps and a term te2 such that
   List.fold_right (fun p acc -> DestructWith p acc) ps te2 == te1
   
   less formally, traversing a term to find the maximum list of DestructWith with only one equation (the next visited term being the r.h.s of the equation)
*)

let rec accumulate_pattern_destructwith (te: term) : (pattern * nature) list * term =
  match te with
    | DestructWith ([(p, te)]) ->
      let (ps, te) = accumulate_pattern_destructwith te in
      (p::ps, te)
    | _ -> ([], te)

(* returns the numbers of bvars introduced by a pattern 
   we should always have 
   pattern_size p = List.length (fst (pattern_bvars p)))
*)
let rec pattern_size (p: pattern) : int =
  match p with
    | PType -> 0
    | PVar (n, ty) -> 1
    | PAVar ty -> 0
    | PCste s -> 0
    | PAlias (n, p, ty) -> 1 + pattern_size p
    | PApp (s, args, ty) -> 
      List.fold_left ( fun acc (hd, _) -> acc + pattern_size hd) 0 args

(* utilities for DoudouException *)

(* makes error more precise *)
let error_left_pos (err: doudou_error) (pos: pos) =
  match err with
    (* there is no pos information for first element *)
    | ErrorPosPair (None, pos2, err) -> ErrorPosPair (Some pos, pos2, err)
    (* our source information is better *)
    | ErrorPosPair (Some pos1, pos2, err) when pos_in pos1 pos -> ErrorPosPair (Some pos, pos2, err)
    (* the given source information is better *)
    | ErrorPosPair (Some pos1, pos2, err) when pos_in pos pos1 -> ErrorPosPair (Some pos1, pos2, err)
    (* else ... *)
    | err -> ErrorPosPair (Some pos, None, err)

let error_right_pos (err: doudou_error) (pos: pos) =
  match err with
    (* there is no pos information for first element *)
    | ErrorPosPair (pos1, None, err) -> ErrorPosPair (pos1, Some pos, err)
    (* our source information is better *)
    | ErrorPosPair (pos1, Some pos2, err) when pos_in pos2 pos -> ErrorPosPair (pos1, Some pos, err)
    (* the given source information is better *)
    | ErrorPosPair (pos1, Some pos2, err) when pos_in pos pos2 -> ErrorPosPair (pos1, Some pos2, err)
    (* else ... *)
    | err -> ErrorPosPair (Some pos, None, err)

let error_pos (err: doudou_error) (pos: pos) =
  match err with
    (* our source information is better *)
    | ErrorPos (pos1, err) when pos_in pos1 pos -> ErrorPos (pos, err)
    (* the given source information is better *)
    | ErrorPos (pos1, err) when pos_in pos pos1 -> ErrorPos (pos1, err)
    (* else ... *)
    | err -> ErrorPos (pos, err)

(* build an implication: no shifting in types !!! *)
let build_impl (symbols: symbol list) (ty: term) (nature: nature) (body: term) : term =
  List.fold_right (fun s acc -> Impl ((s, ty, nature), acc)) symbols body

(* build a destruct with: no shifting in types !!! *)
let build_destructwith (patterns: (pattern * nature) list) (body: term) : term =
  List.fold_right (fun p acc -> DestructWith ([p, acc])) patterns body

let fromSome (e: 'a option) : 'a =
  let Some e = e in e

(*************************************)
(*      substitution/rewriting       *)
(*************************************)

(* substitution = replace variables (free or bound) by terms (used for typechecking/inference with free variables, and for reduction with bound variable) *)



module IndexMap = Map.Make(
  struct
    type t = int
    let compare x y = compare x y
  end
);;

(* substitution: from free variables to term *) 
type substitution = term IndexMap.t;;

(*
  N.B.: rather than duplicating the code for rewriting
*)

(* substitution *)
let rec term_substitution (s: substitution) (te: term) : term =
  match te with
    | Type | Cste _ | Obj _ -> te
    (* generalization for free AND bound variables *)
    | TVar i as v (*when i < 0*) -> 
      (
	try IndexMap.find i s 
	with
	  | Not_found -> v
      )
    (* | TVar i as v when i >= 0 -> v*)
    | AVar -> raise (Failure "term_substitution catastrophic: AVar")
    | TName _ -> raise (Failure "term_substitution catastrophic: TName")
    | App (te, args) ->
      App (term_substitution s te,
	   List.map (fun (te, n) -> term_substitution s te, n) args)
    | Impl ((symb, ty, n), te) ->
      Impl ((symb, term_substitution s ty, n),
	    term_substitution s te)
    | DestructWith eqs ->
      DestructWith (List.map (equation_substitution s) eqs)
    | TyAnnotation (te, ty) -> TyAnnotation (term_substitution s te, term_substitution s ty)
    | SrcInfo (pos, te) -> SrcInfo (pos, term_substitution s te)
and equation_substitution (s: substitution) (eq: equation) : equation =
  let (p, n), te = eq in
  (pattern_substitution s p, n), term_substitution (shift_substitution s (pattern_size p)) te
and pattern_substitution (s: substitution) (p: pattern) : pattern =
  match p with
    | PType -> PType
    | PVar (n, ty) -> PVar (n, term_substitution s ty)
    | PCste s -> PCste s
    | PAlias (n, p, ty) -> PAlias (n, pattern_substitution s p, term_substitution s ty)
    | PApp (symb, args, ty) ->
      PApp (symb,
	    List.map (fun (p, n) -> pattern_substitution s p, n) args,
	    term_substitution s ty)

(* shift vars index in a substitution 
   only bound variable of the l.h.s. of the map are shifted too
*)
and shift_substitution (s: substitution) (delta: int) : substitution =
  IndexMap.fold (fun key value acc -> 
    try 
      let key = if key < 0 then key else 
	  if delta < 0 then raise (Failure "shift_substitution: catastrophic, negative shifting of bound variables") else key + delta 
	    in
      IndexMap.add key (shift_term value delta) acc
    with
      | DoudouException (Unshiftable_term _) -> acc
  ) s IndexMap.empty
      
(* shift bvar index in a term *)
and shift_term (te: term) (delta: int) : term =
  leveled_shift_term te 0 delta

(* shift bvar index in a term, above a given index *)
and leveled_shift_term (te: term) (level: int) (delta: int) : term =
  match te with
    | Type -> Type
    | Cste s -> Cste s
    | Obj o -> Obj o
    | TVar i as v ->
      if i >= level then
	if i + delta < level then
	  raise (DoudouException (Unshiftable_term (te, level, delta)))
	else
	  TVar (i + delta)
      else
	v
    | AVar -> raise (Failure "leveled_shift_term catastrophic: AVar")
    | TName _ -> raise (Failure "leveled_shift_term catastrophic: TName")

    | App (te, args) ->
      App (
	leveled_shift_term te level delta,
	List.map (fun (te, n) -> leveled_shift_term te level delta, n) args
      )
    | Impl ((s, ty, n), te) ->
      Impl ((s, leveled_shift_term ty level delta, n), leveled_shift_term te (level + 1) delta)

    | DestructWith eqs ->
      DestructWith (List.map (fun eq -> leveled_shift_equation eq level delta) eqs)

    | TyAnnotation (te, ty) -> TyAnnotation (leveled_shift_term te level delta, leveled_shift_term ty level delta)

    | SrcInfo (pos, te) -> SrcInfo (pos, leveled_shift_term te level delta)

and leveled_shift_equation (eq: equation) (level: int) (delta: int) : equation =
  let (p, n), te = eq in
  (leveled_shift_pattern p level delta, n), leveled_shift_term te (level + pattern_size p) delta

and leveled_shift_pattern (p: pattern) (level: int) (delta: int) : pattern =
  match p with
    | PType -> PType
    | PVar (n, ty) -> PVar (n, leveled_shift_term ty level delta)
    | PAVar ty -> PAVar (leveled_shift_term ty level delta)
    | PAlias (s, p, ty) -> PAlias (s, leveled_shift_pattern p level delta, leveled_shift_term ty level delta)
    | PApp (s, args, ty) ->
      PApp (s,
	    List.map (fun (p, n) -> leveled_shift_pattern p level delta, n) args,
	    leveled_shift_term ty level delta)


(********************************)
(*      defs/context/frame      *)
(********************************)

(* build a new frame 
   value is optional
*)
let build_new_frame (s: symbol) ?(value: term = TVar 0) (ty: term) : frame =
{ 
  symbol = s;
  ty = ty;
  value = value;

  fvs = [];
  termstack = [];
  naturestack = [];
  equationstack = [];
  patternstack = [];

}

(* push the bvars of a pattern in a context *)
let push_pattern_bvars (ctxt: context) (l: (name * term * term) list) : context =
  List.fold_left (fun ctxt (n, ty, v) ->
    (
      build_new_frame (Name n) ~value:v ty
    ) :: ctxt	     

  ) ctxt l


(* returns the list of bound variables, their value (w.r.t. other bound variable) and their type in a pattern 
   the order is such that 
   it also returns the overall value of the pattern (under the pattern itself)
   hd::tl -> hd is the "oldest" variable, and is next to be framed
*)

let rec pattern_bvars (p: pattern) : (name * term * term) list * term =
  match p with
    | PType -> [], Type
    | PVar (n, ty) -> [n, shift_term ty 1, TVar 0], TVar 0
    | PAVar ty -> ["_", shift_term ty 1, TVar 0], TVar 0
    | PCste s -> [] , Cste s
    | PAlias (n, p, ty) -> 
      let l, te = pattern_bvars p in
      (* the value is shift by one (under the alias-introduced var) *)
      let te = shift_term te 1 in
	(l @ [n, shift_term ty (1 + List.length l), te], te)
    | PApp (s, args, ty) -> 
      let (delta, l, rev_values) = 
	(* for sake of optimization the value list is in reverse order *)
	List.fold_left (fun (delta, l, rev_values) (p, n) ->
	  (* first we grab the result for p *)
	  let (pl, te) = pattern_bvars p in
	  (* then we need to shift the value term by the current delta level *)
	  let te = shift_term te delta in
	  (* we update the delta value, and returns the concatenation *)
	  (delta + List.length l, l @ pl, (te, n)::rev_values)
	) (0, [], []) args in
      (l, App (Cste s, List.rev rev_values))


(* compute the context under a pattern *)
let push_pattern (ctxt: context) (p: pattern) : context =
  (* we extract the list of bound variable in the pattern *)
  let (bvars, _) = pattern_bvars p in
  (* we build a new context with the pattern bvars frames pushed *)
  push_pattern_bvars ctxt bvars

(* apply a substitution in a context *)
let context_substitution (s: substitution) (ctxt: context) : context =
  fst (mapacc (fun s frame ->
    { frame with
      ty = term_substitution s frame.ty;
      (* not sure on this one ... there should be no fv in value ... *)
      value = term_substitution s frame.value;
      fvs = List.map (fun (index, ty, value) -> index, term_substitution s ty, term_substitution s value) frame.fvs;
      termstack = List.map (term_substitution s) frame.termstack;
      equationstack = List.map (equation_substitution s) frame.equationstack;
      patternstack = List.map (pattern_substitution s) frame.patternstack
    }, shift_substitution s 1
  ) s ctxt
  )

(* retrieve the debruijn index of a bound var through its symbol *)
let bvar_lookup (ctxt: context) (s: symbol) : index option =
  let res = fold_stop (fun level frame ->
    if symbol2string frame.symbol = symbol2string s then
      Right level
    else
      Left (level + 1)
  ) 0 ctxt in
  match res with
    | Left _ -> None
    | Right level -> Some level

(* grab the value of a bound var *)
let bvar_value (ctxt: context) (i: index) : term =
  try (
    let frame = List.nth ctxt i in
    let value = frame.value in
    shift_term value i
  ) with
    | Failure "nth" -> raise (DoudouException (UnknownBVar (i, ctxt)))
    | Invalid_argument "List.nth" -> raise (DoudouException (NegativeIndexBVar i))

(* grab the type of a bound var *)
let bvar_type (ctxt: context) (i: index) : term =
  try (
    let frame = List.nth ctxt i in
    let ty = frame.ty in
    shift_term ty i
  ) with
    | Failure "nth" -> raise (DoudouException (UnknownBVar (i, ctxt)))
    | Invalid_argument "List.nth" -> raise (DoudouException (NegativeIndexBVar i))

(* grab the value of a free var *)
let fvar_value (ctxt: context) (i: index) : term =
  let lookup = fold_stop (fun level frame ->
    let lookup = fold_stop (fun () (index, ty, value) -> 
      if index = i then Right value else Left ()
    ) () frame.fvs in
    match lookup with
      | Left () -> Left (level + 1)
      | Right res -> Right (shift_term res level)
  ) 0 ctxt in
  match lookup with
    | Left _ -> raise (DoudouException (UnknownFVar (i, ctxt)))
    | Right res -> res

(* grab the type of a free var *)
let fvar_type (ctxt: context) (i: index) : term =
  let lookup = fold_stop (fun level frame ->
    let lookup = fold_stop (fun () (index, ty, value) -> 
      if index = i then Right ty else Left ()
    ) () frame.fvs in
    match lookup with
      | Left () -> Left (level + 1)
      | Right res -> Right (shift_term res level)
  ) 0 ctxt in
  match lookup with
    | Left _ -> raise (DoudouException (UnknownFVar (i, ctxt)))
    | Right res -> res

(* extract a substitution from the context *)
let context2substitution (ctxt: context) : substitution =
  fst (List.fold_left (
    fun (s, level) frame -> 
      let s = List.fold_left (fun s (index, ty, value) ->
	(* add : key -> 'a -> 'a t -> 'a t *)
	IndexMap.add index (shift_term value level) s
      ) s frame.fvs in
      (s, level+1)
  ) (IndexMap.empty, 0) ctxt
  )

(* pushing and poping terms in the term stack 
   N.B.: with side effect
*)
let push_terms (ctxt: context ref) (tes: term list) : unit =
  let (hd::tl) = !ctxt in
  ctxt := ({hd with termstack = tes @ hd.termstack})::tl

let pop_terms (ctxt: context ref) (sz: int) : term list =
  let (hd::tl) = !ctxt in  
  ctxt := ({hd with termstack = drop sz hd.termstack})::tl;
  take sz hd.termstack

(* unfold a constante *)
let unfold_constante (defs: defs) (s: symbol) : term option =
  try 
    (fun (_, _, value) -> value) (Hashtbl.find defs.store (symbol2string s))
  with
    | Not_found -> raise (DoudouException (UnknownCste s))

(* grab the type of a constante *)
let constante_type (defs: defs) (s: symbol) : term =
  try 
    (fun (_, ty, _) -> ty) (Hashtbl.find defs.store (symbol2string s))
  with
    | Not_found -> raise (DoudouException (UnknownCste s))

(* grab the real symbol of a constante *)
let constante_symbol (defs: defs) (s: symbol) : symbol =
  try 
    (fun (s, _, _) -> s) (Hashtbl.find defs.store (symbol2string s))
  with
    | Not_found -> raise (DoudouException (UnknownCste s))

(* push / pop a frame *)
let pop_frame (ctxt: context) : context =
  match List.hd ctxt with
    | { fvs = []; termstack = []; naturestack = []; equationstack = []; patternstack = []; _} ->
      List.tl ctxt
    | { termstack = []; naturestack = []; equationstack = []; patternstack = []; _} ->
      raise (Failure "Case not yet supported, pop_frame with still fvs")
    | _ -> raise (DoudouException (PoppingNonEmptyFrame (List.hd ctxt)))

let rec pop_frames (ctxt: context) (nb: int) : context =
  if nb <= 0 then ctxt else pop_frames (pop_frame ctxt) (nb - 1)

(*************************************************************)
(*      unification/reduction, type{checking/inference}      *)
(*************************************************************)

(*
  reduction of terms
  several strategy are possible:
  for beta reduction: Lazy or Eager
  possibility to have strong beta reduction
  delta: unfold equations (replace cste with their equations)
  iota: try to match equations l.h.s
  deltaiotaweak: if after delta reduction (on head of app), a iota reduction fails, then the delta reduction is backtracked
  deltaiotaweak_armed: just a flag to tell the reduction function that it should raise a IotaReductionFailed
  zeta: compute the let bindings
  eta: not sure if needed

  all these different strategy are used for several cases: unification, typechecking, ...
  
*)

(* for now only eager is implemented !!!*)
type strategy = 
  | Lazy 
  | Eager

type reduction_strategy = {
  beta: strategy;
  betastrong: bool;
  delta: bool;
  iota: bool;
  deltaiotaweak: bool;
  deltaiotaweak_armed: bool;
  zeta: bool;
  eta: bool;
}

let unification_strat : reduction_strategy = {
  beta = Eager;
  betastrong = false;
  delta = true;
  iota = true;
  deltaiotaweak = false;
  deltaiotaweak_armed = false;
  zeta = true;
  eta = true;
}



(* unification pattern to term *)
(*
  this is quite conservative:
  - we do not "reformat" application. so the unification is not modulo right associativity of applicatino
  - we ask for equality of symbol for constant, rather than looking for possible alias
*)
let rec unification_pattern_term (ctxt: context) (p: pattern) (te:term) : substitution =
  match p, te with
    | PType, Type -> IndexMap.empty
    | PVar (n, ty), te -> IndexMap.singleton 0 (shift_term te 1)
    | PAVar _, te -> IndexMap.empty
    | PCste s1, Cste s2 when s1 = s2 -> IndexMap.empty
    | PCste s1, Cste s2 when s1 != s2 -> raise (DoudouException (NoMatchingPattern (ctxt, p, te)))
    | PAlias (n, p, ty), te ->
      (* grab the substitution *)
      let s = unification_pattern_term ctxt p te in
      (* shift it by one (for the n of the alias) *)
      let s = shift_substitution s 1 in
      (* we put in the substitution the shifting of te by |s| + 1 at index 0 *)
      IndexMap.add 0 (shift_term te (IndexMap.cardinal s + 1)) s
    (* for the application, we only accept same constante as head and same number of arguments 
       this is really conservatives .. we could implement the same mechanism as in subtitution_term_term
    *)
    | PApp (s1, args1, ty), App (Cste s2, args2) when List.length args1 = List.length args2 && s1 = s2 ->
      (* we unify arguments one by one (with proper shifting) *)
      List.fold_left (fun s ((arg1, n1), (arg2, n2)) -> 
	(* first we unify both args *)
	let s12 = unification_pattern_term ctxt p te in
	(* we need to shift the accumulator by the number of introduced free variable == caridnality of s12 *)
	let s = shift_substitution s12 (IndexMap.cardinal s12) in
	(* and we just return the union (making sure no key are duplicated)
	   merge : (key -> 'a option -> 'b option -> 'c option) ->
	   'a t -> 'b t -> 'c t
	*)
	IndexMap.merge (fun k val1 val2 ->
	  match val1, val2 with
	    | None, None -> raise (Failure "unification_pattern_term: catastrophic, both value for a given key are None")
	    | Some _, Some _ -> raise (Failure "unification_pattern_term: catastrophic, both value for a given key are Some ==> it means that a bound variable is duplicated, and thus the shifting in substitution is not properly done!")
	    | Some v, None -> Some v
	    | None, Some v -> Some v
	)  s s12
      ) IndexMap.empty (List.combine args1 args2)
      

(* a special exception for the reduction which 
   signals that an underlying iota reduction fails
*)
exception IotaReductionFailed

let rec unification_term_term (defs: defs) (ctxt: context ref) (te1: term) (te2: term) : term =
  match te1, te2 with

    (* first the cases for SrcInfo and TyAnnotation *)

    | SrcInfo (pos, te1), _ -> (
      try 
	unification_term_term defs ctxt te1 te2
      with
	| DoudouException err -> raise (DoudouException (error_left_pos err pos))
    )

    | _, SrcInfo (pos, te2) -> (
      try 
	unification_term_term defs ctxt te1 te2
      with
	| DoudouException err -> raise (DoudouException (error_right_pos err pos))
    )

    | TyAnnotation (te1, ty1), TyAnnotation (te2, ty2) ->
      (* we push ty1 and ty2, so that they will be substituted with the result of the substitution of te1 te2 *)
      push_terms ctxt [ty1; ty2];
      let te = unification_term_term defs ctxt te1 te2 in
      (* we pop back ty1 and ty2 *)
      let [ty1; ty2] = pop_terms ctxt 2 in
      let ty = unification_term_term defs ctxt ty1 ty2 in
      TyAnnotation (te, ty)

    (* and the two cases above, we need to unify the annotated type with the infered type 
       not sure this is really needed ... but 
    *)
    | TyAnnotation (te1, ty1), _ ->
      (* pushing ty1 *)
      push_terms ctxt [ty1];
      let (te2, ty2) = typeinfer defs ctxt te2 in
      (* poping ty1 *)
      let [ty1] = pop_terms ctxt 1 in
      unification_term_term defs ctxt (TyAnnotation (te1, ty1)) (TyAnnotation (te2, ty2))

    | _, TyAnnotation (te2, ty2) ->
      (* pushing ty1 *)
      push_terms ctxt [ty2];
      let (te1, ty1) = typeinfer defs ctxt te1 in
      (* poping ty2 *)
      let [ty2] = pop_terms ctxt 1 in
      unification_term_term defs ctxt (TyAnnotation (te1, ty1)) (TyAnnotation (te2, ty2))

    (* the error cases for AVar and TName *)
    | AVar, _ -> raise (Failure "unification_term_term catastrophic: AVar in te1 ")
    | _, AVar -> raise (Failure "unification_term_term catastrophic: AVar in te2 ")
    | TName _, _ -> raise (Failure "unification_term_term catastrophic: TName in te1 ")
    | _, TName _ -> raise (Failure "unification_term_term catastrophic: TName in te2 ")


    (* the trivial cases for Type, Cste and Obj *)
    | Type, Type -> Type
    | Obj o1, Obj o2 when o1 = o2 -> Obj o1
    | Cste c1, Cste c2 when c1 = c2 -> Cste c1
    (* when a term is a constant we just unfold it *)
    | Cste c1, _ when unfold_constante defs c1 != None -> unification_term_term defs ctxt (fromSome (unfold_constante defs c1)) te2
    | _, Cste c2 when unfold_constante defs c2 != None -> unification_term_term defs ctxt te1 (fromSome (unfold_constante defs c2))

    (* the trivial case for variable *)
    | TVar i1, TVar i2 when i1 = i2 -> TVar i1
    (* the case for free variables *)
    (* we need the free var to not be a free var of the term *)
    | TVar i1, _ when i1 < 0 && not (IndexSet.mem i1 (fv_term te2))->
      let s = IndexMap.singleton i1 te2 in
      ctxt := context_substitution s (!ctxt);
      (* should we rewrite subst in te2 ? a priori no:
	 1- i not in te2
	 2- if s introduce a possible substitution, it means that i was in te2 by transitives substitution
	 and that we did not comply with the N.B. above
      *)
      te2      
	  
    | _, TVar i2 when i2 < 0 && not (IndexSet.mem i2 (fv_term te1))->
      let s = IndexMap.singleton i2 te1 in
      ctxt := context_substitution s (!ctxt);
      (* should we rewrite subst in te2 ? a priori no:
	 1- i not in te2
	 2- if s introduce a possible substitution, it means that i was in te2 by transitives substitution
	 and that we did not comply with the N.B. above
      *)
      te1
    (* in other cases, the frame contains the value for a given bound variable. If its not itself, we should unfold *)
    | TVar i1, _ when i1 >= 0 && bvar_value !ctxt i1 != TVar i1 ->
      unification_term_term defs ctxt (bvar_value !ctxt i1) te2
    | _, TVar i2 when i2 >= 0 && bvar_value !ctxt i2 != TVar i2 ->
      unification_term_term defs ctxt te1 (bvar_value !ctxt i2)

    (* the case of two application: with not the same arity *)
    | App (hd1, args1), App (hd2, args2) when List.length args1 != List.length args2 ->
      (* first we try to change them such that they have the same number of arguments and try to match them *)
      let min_arity = min (List.length args1) (List.length args2) in
      let te1' = if List.length args1 = min_arity then te1 else App (App (hd1, take (List.length args1 - min_arity) args1), drop (List.length args1 - min_arity) args1) in
      let te2' = if List.length args2 = min_arity then te2 else App (App (hd2, take (List.length args2 - min_arity) args2), drop (List.length args2 - min_arity) args2) in
      (* we save the current context somewhere to rollback *)
      let saved_ctxt = !ctxt in
      (try 
	 unification_term_term defs ctxt te1' te2' 
       with
	 (* apparently it does not work, so we try to reduce them *)
	 | DoudouException _ ->
	   (* restore the context *)
	   ctxt := saved_ctxt;
	   (* reducing them *)
	   let te1' = reduction defs ctxt unification_strat te1 in
	   let te2' = reduction defs ctxt unification_strat te2 in
	   (* if both are still the sames, we definitely do not know if they can be unify, else we try to unify the new terms *)
	   if te1 = te1' && te2 = te2' then raise (DoudouException (UnknownUnification (!ctxt, te1, te2))) else unification_term_term defs ctxt te1' te2'
      )
    (* the case of two application with same arity *)
    | App (hd1, args1), App (hd2, args2) when List.length args1 = List.length args2 ->
      (* first we save the context and try to unify all term component *)
      let saved_ctxt = !ctxt in
      (try
	 (* we need to push the arguments (through this we also verify that the nature matches ) *)
	 (* we build a list where arguments of te1 and te2 are alternate *)
	 let rev_arglist = List.fold_left (
	   fun acc ((arg1, n1), (arg2, n2)) ->
	     if n1 != n2 then
	     (* if both nature are different -> no unification ! *)
	       raise (DoudouException (NoUnification (!ctxt, te1, te2)))
	     else  
	       arg2::arg1::acc
	 ) [] (List.combine args1 args2) in
	 let arglist = List.rev rev_arglist in
	 (* and we push this list *)
	 push_terms ctxt arglist;
	 (* first we unify the head of applications *)
	 let hd = unification_term_term defs ctxt hd1 hd2 in
	 (* then we unify all the arguments pair-wise, taking them from the list *)
	 let args = List.map (fun (_, n) ->
	   (* we grab the next argument for te1 and te2 in the context (and we know that their nature is equal to n) *)
	   let [arg1; arg2] = pop_terms ctxt 2 in
	   (* and we unify *)
	   let arg = unification_term_term defs ctxt arg1 arg2 in
	   (arg, n)
	 ) args1 in
	 (* finally we have our unified term ! *)
	 App (hd, args)

       with
	 (* apparently it does not work, so we try to reduce them *)
	 | DoudouException _ ->
	   (* restore the context *)
	   ctxt := saved_ctxt;
	   (* reducing them *)
	   let te1' = reduction defs ctxt unification_strat te1 in
	   let te2' = reduction defs ctxt unification_strat te2 in
	   (* if both are still the sames, we definitely do not know if they can be unify, else we try to unify the new terms *)
	   if te1 = te1' && te2 = te2' then raise (DoudouException (UnknownUnification (!ctxt, te1, te2))) else unification_term_term defs ctxt te1' te2'
      )	
    (* the cases where only one term is an Application: we should try to reduce it if possible, else we do not know! *)
    | App (hd1, args1), _ ->
      let te1' = reduction defs ctxt unification_strat te1 in
      if te1 = te1' then raise (DoudouException (UnknownUnification (!ctxt, te1, te2))) else unification_term_term defs ctxt te1' te2
    | _, App (hd2, args2) ->
      let te2' = reduction defs ctxt unification_strat te2 in
      if te2 = te2' then raise (DoudouException (UnknownUnification (!ctxt, te1, te2))) else unification_term_term defs ctxt te1 te2'

    (* the impl case: only works if both are impl *)
    | Impl ((s1, ty1, n1), te1), Impl ((s2, ty2, n2), te2) ->
      (* the symbol is not important, yet the nature is ! *)
      if n1 != n2 then raise (DoudouException (NoUnification (!ctxt, te1, te2))) else
	(* we unify the types *)
	let ty = unification_term_term defs ctxt ty1 ty2 in
	(* we push a frame *)
	let frame = build_new_frame s1 (shift_term ty 1) in
	ctxt := frame::!ctxt;
	(* we need to substitute te1 and te2 with the context substitution (which might have been changed by unification of ty1 ty2) *)
	let s = context2substitution !ctxt in
	let te1 = term_substitution s te1 in
	let te2 = term_substitution s te2 in
	(* we unify *)
	let te = unification_term_term defs ctxt te1 te2 in
	(* we pop the frame *)
	ctxt := pop_frame !ctxt;
	(* and we return the term *)
	Impl ((s1, ty, n1), te)

    (* for now we do not allow unification of DestructWith *)
    | DestructWith eqs1, DestructWith eq2 ->
      printf "WARNING: unification_term_term: DestructWith\n";
      raise (DoudouException (UnknownUnification (!ctxt, te1, te2)))

    (* for all the rest: I do not know ! *)
    | _ -> 
      printf "WARNING: unification_term_term: case not explicitely defined\n";
      raise (DoudouException (UnknownUnification (!ctxt, te1, te2)))

and reduction (defs: defs) (ctxt: context ref) (strat: reduction_strategy) (te: term) : term = 
  match te with
    | SrcInfo (pos, te) -> (
      try 
	reduction defs ctxt strat te
      with
	| DoudouException err -> raise (DoudouException (error_left_pos err pos))
    )
    | TyAnnotation (te, ty) ->
      let te = reduction defs ctxt strat te in
      let ty = reduction defs ctxt strat ty in
      TyAnnotation (te, ty)

    | Type -> Type
    (* without delta reduction we do unfold *)
    | Cste c1 when not strat.delta -> te
    (* with delta reduction we unfold *)
    | Cste c1 when strat.delta && unfold_constante defs c1 != None -> fromSome (unfold_constante defs c1)

    | Obj o -> te

    (* for both free and bound variables we have their value in the context *)
    | TVar i when i >= 0 -> bvar_value !ctxt i
    | TVar i when i < 0 -> fvar_value !ctxt i

    (* trivial error cases *) 
    | AVar -> raise (Failure "reduction catastrophic: AVar")
    | TName _ -> raise (Failure "reduction catastrophic: TName")

    (* Impl: we reduce the type, and the term only if betastrong *)
    | Impl ((s, ty, n), te) -> 
      let ty = reduction defs ctxt strat ty in
      if strat.betastrong then (
	(* we push a frame *)
	let frame = build_new_frame s (shift_term ty 1) in
	ctxt := frame::!ctxt;
	(* we reduce the body *)
	let te = reduction defs ctxt strat te in
	(* we pop the frame *)
	ctxt := pop_frame !ctxt;
	(* and we return the term *)
	Impl ((s, ty, n), te)

      ) else Impl ((s, ty, n), te)
    
    (* DestructWith: we only go down if betastrong *)
    | DestructWith eqs when not strat.betastrong -> te
    | DestructWith eqs when strat.betastrong -> 
      let eqs = List.map (fun ((p, n), te) ->
	(* maybe we should reduce the type annotation in pattern? ... humpf *)
	let p = (fun x -> x) p in
	(* we push the bvar generated by the pattern in the context *)	
	ctxt := push_pattern !ctxt p;
	(* we reduce the body *)
	let te = reduction defs ctxt strat te in
	(* we pop the frames *)
	ctxt := pop_frames !ctxt (pattern_size p);
	((p, n), te)
      ) eqs in
      DestructWith eqs

    (* Application: the big part *)
    (* for no only Eager is implemented *)
    | App _ when strat.beta = Eager -> (

      (* we do a case analysis ... *)

      match te with
	  
	(* a first subcase for app: with a Cste as head *)
	(* in case of deltaiota weakness, we need to catch the IotaReductionFailed exception *) 
	| App (Cste c1, args) when strat.deltaiotaweak && unfold_constante defs c1 != None -> (
	  (* first we save the context *)
	  let saved_ctxt = !ctxt in
	  (* we unfold the constante *)
	  let te1 = fromSome (unfold_constante defs c1) in
	  try 
	    reduction defs ctxt {strat with deltaiotaweak_armed = true} (App (te1, args))
	  with
	    | IotaReductionFailed -> 
	  (* we restore the context *)
	      ctxt := saved_ctxt;
	      App (Cste c1, args)
	)

	(* App is right associative ... *)
	| App (App (te1, args1), arg2) ->
	  reduction defs ctxt strat (App (te1, args1 @ arg2))

	(* the real stuffs: application on a destruct with *)
	| App (DestructWith eqs, arg::args) -> 
	  (
	    let (argte, argn) = arg in
	    (* we reduce the arguments *)
	    let argte = reduction defs ctxt strat argte in
	    (* yet it means that the arguments are reduce a lots of times .... so remove the next line, such that only the arg needed will be reduce *)
	    (*let args = List.map (fun (arg, n) -> reduction defs ctxt strat arg, n) args in*)
	    (* we try all the equation until finding one that unify with arg *)
	    let match_pattern = fold_stop (fun () ((p, n), body) ->
	      (* we could check that n = argn, but it should have been already checked *)
	      (* can we unify the pattern ? *)
	      try 
		Right (unification_pattern_term !ctxt p argte, body)
	      with
		| DoudouException (NoMatchingPattern _) -> Left ()
	    ) () eqs in
	    match match_pattern with
	      | Left () ->
		(* no pattern were unifiable: return the term as it 
		   except if deltaiotaweak and ..._armed are set
		*)
		if strat.deltaiotaweak && strat.deltaiotaweak_armed then
		  raise IotaReductionFailed
		else
		  App (DestructWith eqs, (argte, argn)::args)
	      (* we have one pattern that is ok *)
	      | Right (r, body) ->
		(* we rewrite the bound variables from the unification *)
		let body = term_substitution r body in
		(* we can now shift the term by the size of the rewrite *)
		shift_term body (IndexMap.cardinal r)	    

	  )
	| App (hd, args) ->
	  App (hd, List.map (fun (arg, n) -> reduction defs ctxt strat arg, n) args)

    )
and typecheck (defs: defs) (ctxt: context ref) (te: term) (ty: term) : term * term =
  (* save the context *)
  let saved_ctxt = !ctxt in
  try (
  match te, ty with
    (* one basic rule, Type :: Type *)
    | Type, Type -> Type, Type

    (* here we should have the case for which you cannot rely on the inference *)


    (* the most basic typechecking strategy, 
       infer the type ty', typecheck it with Type (really needed ??) and unify with ty    
    *)
    | _, _ ->
      let te, ty' = typeinfer defs ctxt te in
      let ty', _ = typecheck defs ctxt ty' Type in
      let ty = unification_term_term defs ctxt ty ty' in
      te, ty

  ) with
    | DoudouException ((CannotTypeCheck _) as err) ->
      raise (DoudouException err)
    | DoudouException err ->
      ctxt := saved_ctxt;
      let te, inferedty = typeinfer defs ctxt te in
      raise (DoudouException (CannotTypeCheck (!ctxt, te, inferedty, ty, err)))
      
and typeinfer (defs: defs) (ctxt: context ref) (te: term) : term * term =
  (* save the context *)
  let saved_ctxt = !ctxt in
  try (
  match te with
    | SrcInfo (pos, te) ->
      let te, ty = typeinfer defs ctxt te in
      SrcInfo (pos, te), ty

    | TyAnnotation (te, ty) -> 
      let ty, _ = typecheck defs ctxt ty Type in
      let te, ty = typecheck defs ctxt te ty in
      TyAnnotation (te, ty), ty

    | Type -> Type, Type

    | Cste c1 -> Cste c1, constante_type defs c1

    | Obj o -> Obj o, o#get_type

    | TVar i when i >= 0 -> TVar i, bvar_type !ctxt i
    | TVar i when i < 0 -> TVar i, fvar_type !ctxt i

    | TName s -> (
      (* we first look for a bound variable *)
      match bvar_lookup !ctxt s with
	| Some i -> 
	  let te = TVar i in
	  let ty = bvar_type !ctxt i in
	  te, ty
	| None -> 
	  (* we look for a constante *)
	  let te = Cste (constante_symbol defs s) in
	  let ty = constante_type defs s in
	  te, ty
    )


    | AVar -> raise (Failure "typeinfer: Case not yet supported, AVar")
    | App _ -> raise (Failure "typeinfer: Case not yet supported, App")
    | Impl _ -> raise (Failure "typeinfer: Case not yet supported, Impl")
    | DestructWith _ -> raise (Failure "typeinfer: Case not yet supported, DestructWith")
  ) with
    | DoudouException ((CannotInfer _) as err) ->
      raise (DoudouException err)
    | DoudouException err ->
      ctxt := saved_ctxt;
      raise (DoudouException (CannotInfer (!ctxt, te, err)))
          

      
(******************)
(* pretty printer *)
(******************)

(*
  helper functions
*)
let rec intercalate (inter: 'a) (l: 'a list) : 'a list =
  match l with
    | hd1::hd2::tl ->
      hd1::inter::(intercalate inter (hd2::tl))
    | _ -> l

let rec intercalates (inter: 'a list) (l: 'a list) : 'a list =
  match l with
    | hd1::hd2::tl ->
      hd1::inter @ intercalates inter (hd2::tl)
    | _ -> l

let rec withParen (t: token) : token =
  Box [Verbatim "("; t; Verbatim ")"]

let rec withBracket (t: token) : token =
  Box [Verbatim "{"; t; Verbatim "}"]

(* a data structure to mark the place where the term/pattern is *)
type place = InNotation of op * int (* in the sndth place of the application to the notation with op *)
	     | InApp (* in the head of application *)
	     | InArg of nature (* as an argument (Explicit) *)
	     | InAlias  (* in an alias pattern *)
	     | Alone (* standalone *)

(* TODO: add options for 
   - printing implicit terms 
   - printing type annotation
   - source info
*)

(* transform a term into a box *)
let rec term2token (ctxt: context) (te: term) (p: place): token =
  match te with
    | Type -> Verbatim "Type"
    | Cste s -> Verbatim (symbol2string s)
    | Obj o -> o#pprint ()
    | TVar i when i >= 0 -> 
      let frame = get_bvar_frame ctxt i in
      Verbatim (symbol2string (frame.symbol))
    | TVar i when i < 0 -> 
      Verbatim (String.concat "" ["["; string_of_int i;"]"])

    (* we need to split App depending on the head *)
    (* the case for notation Infix *)
    | App (Cste (Symbol (s, Infix (myprio, myassoc))), args) when List.length (filter_explicit args) = 2->
      (* we should put parenthesis in the following condition: *)
      (match p with
	(* if we are an argument *)
	| InArg Explicit -> withParen
	(* if we are in a notation such that *)
	(* a prefix or postfix binding more  than us *)
	| InNotation (Prefix i, _) when i > myprio -> withParen
	| InNotation (Postfix i, _) when i > myprio -> withParen
	(* or another infix with higher priority *)
	| InNotation (Infix (i, _), _) when i > myprio -> withParen
	(* or another infix with same priority depending on the associativity and position *)
	(* I am the first argument and its left associative *)
	| InNotation (Infix (i, LeftAssoc), 1) when i = myprio -> withParen
	(* I am the second argument and its right associative *)
	| InNotation (Infix (i, RightAssoc), 2) when i = myprio -> withParen

	(* else we do not need parenthesis *)
	| _ -> fun x -> x
      )	(
	match filter_explicit args with
	  | arg1::arg2::[] ->
	    let arg1 = term2token ctxt arg1 (InNotation (Infix (myprio, myassoc), 1)) in
	    let arg2 = term2token ctxt arg2 (InNotation (Infix (myprio, myassoc), 2)) in
	    let te = Verbatim s in
	    Box (intercalate (Space 1) [arg1; te; arg2])
	  | _ -> raise (Failure "term2token, App infix case: irrefutable patten")
       )
    (* the case for Prefix *)
    | App (Cste (Symbol (s, (Prefix myprio))), args) when List.length (filter_explicit args) = 1 ->
      (* we put parenthesis when
	 - as the head or argument of an application
	 - in a postfix notation more binding than us
      *)
      (match p with
	| InArg Explicit -> withParen
	| InApp -> withParen
	| InNotation (Postfix i, _) when i > myprio -> withParen
	| _ -> fun x -> x
      ) (
	match filter_explicit args with
	  | arg::[] ->
	    let arg = term2token ctxt arg (InNotation (Prefix myprio, 1)) in
	    let te = Verbatim s in
	    Box (intercalate (Space 1) [te; arg])
	  | _ -> raise (Failure "term2token, App prefix case: irrefutable patten")
       )

    (* the case for Postfix *)
    | App (Cste (Symbol (s, (Postfix myprio))), args) when List.length (filter_explicit args) = 1 ->
      (* we put parenthesis when
	 - as the head or argument of an application
	 - in a prefix notation more binding than us
      *)
      (match p with
	| InArg Explicit -> withParen
	| InApp -> withParen
	| InNotation (Prefix i, _) when i > myprio -> withParen
	| _ -> fun x -> x
      ) (
	match filter_explicit args with
	  | arg::[] ->
	    let arg = term2token ctxt arg (InNotation (Postfix myprio, 1)) in
	    let te = Verbatim s in
	    Box (intercalate (Space 1) [arg; te])
	  | _ -> raise (Failure "term2token, App postfix case: irrefutable patten")
       )

    (* general case *)
    | App (te, args) ->
      (* we only embed in parenthesis if
	 - we are an argument of an application
	 - we are in a notation
      *)
      (match p with
	| InArg Explicit -> withParen
	| InNotation _ -> withParen
	| _ -> fun x -> x
      ) (
	let args = List.map (fun te -> term2token ctxt te (InArg Explicit)) (filter_explicit args) in
	let te = term2token ctxt te InApp in
	Box (intercalate (Space 1) (te::args))
       )

    (* implication *)
    | Impl ((s, ty, nature), te) ->
      (* we embed in parenthesis if 
	 - embed as some arg 
	 - ??
      *)
      (
	match p with
	  | InArg Explicit -> withParen
	  | _ -> fun x -> x
      )
	(
	  (* the lhs of the ->*)
	  let lhs = 
	    (* if the symbol is Nofix _ -> we skip the symbol *)
	    (* IMPORTANT: it means that Symbol ("_", Nofix)  as a special meaning !!!! *)
	    match s with
	      | Symbol ("_", Nofix) ->
		(* we only put brackets if implicit *)
		(if nature = Implicit then withBracket else fun x -> x)
		  (term2token ctxt ty (InArg nature))
	      | _ -> 
		(* here we put the nature marker *)
		(if nature = Implicit then withBracket else withParen)
		  (Box [Verbatim (symbol2string s); Space 1; Verbatim "::"; Space 1; term2token ctxt ty Alone])
	  in 
	  (* for computing the r.h.s, we need to push a new frame *)
	  let newframe = build_new_frame s (shift_term ty 1) in
	  let rhs = term2token (newframe::ctxt) te Alone in
	  Box [lhs; Space 1; Verbatim "->"; Space 1; rhs]
	)

    | DestructWith eqs ->
      (* we do not put parenthesis only when
	 - we are alone
      *)
      (
	match p with
	  | Alone -> (fun x -> x)
	  | _ -> withParen
      )
      (
	(* we extract the accumulation of destructwith *)
	let (ps, te) = accumulate_pattern_destructwith te in
	match ps with
	  (* if ps is empty -> do something basic *)
	  | [] ->
	    let eqs = List.map (fun eq -> equation2token ctxt eq) eqs in
	    Box (intercalates [Newline; Verbatim "|"; Space 1] eqs)
	  (* else we do more prettty printing *)
	  | _ ->
	    let (ps, ctxt) = List.fold_left (fun (ps, ctxt) (p, nature)  -> 

	      (* N.B.: we are printing even the implicit arguments ... is it always a good thing ? *)

	      (* we print the pattern *)
	      let pattern = (if nature = Implicit then withBracket else fun x -> x) (pattern2token ctxt p (InArg nature)) in
	      (* grab the underlying context *)
	      let ctxt = push_pattern ctxt p in
	      (* we return the whole thing *)
	      (* NB: for sake of optimization we return a reversed list of pattern, which are reversed in the final box *)
	      ((pattern::ps), ctxt)
	    ) ([], ctxt) ps in
	      let te = term2token ctxt te Alone in
	      Box (intercalate (Space 1) (List.rev ps) @ [Space 1; Verbatim ":="; Space 1; te])
      )
    | TyAnnotation (te, _) | SrcInfo (_, te) ->
      term2token ctxt te p      

    | AVar -> raise (Failure "term2token - catastrophic: still an AVar in the term")
    | TName _ -> raise (Failure "term2token - catastrophic: still an TName in the term")


and equation2token (ctxt: context) (eq: equation) : token =
  (* here we simply print the DestructWith with only one equation *)
  term2token ctxt (DestructWith [eq]) Alone

and pattern2token (ctxt: context) (pattern: pattern) (p: place) : token =
  match pattern with
    | PType -> Verbatim "Type"
    | PVar (n, _) -> Verbatim n
    | PAVar _ -> Verbatim "_"
    | PCste s -> Verbatim (symbol2string s)
    | PAlias (n, pattern, _) -> Box [Verbatim n; Verbatim "@"; pattern2token ctxt pattern InAlias]

    (* for the append we have several implementation that mimics the ones for terms *)
    | PApp (Symbol (s, Infix (myprio, myassoc)), args, _) when List.length (filter_explicit args) = 2->
      (* we should put parenthesis in the following condition: *)
      (match p with
	(* if we are an argument *)
	| InArg Explicit -> withParen
	(* if we are in a notation such that *)
	(* a prefix or postfix binding more  than us *)
	| InNotation (Prefix i, _) when i > myprio -> withParen
	| InNotation (Postfix i, _) when i > myprio -> withParen
	(* or another infix with higher priority *)
	| InNotation (Infix (i, _), _) when i > myprio -> withParen
	(* or another infix with same priority depending on the associativity and position *)
	(* I am the first argument and its left associative *)
	| InNotation (Infix (i, LeftAssoc), 1) when i = myprio -> withParen
	(* I am the second argument and its right associative *)
	| InNotation (Infix (i, RightAssoc), 2) when i = myprio -> withParen
	(* if we are in an alias *)
	| InAlias -> withParen

	(* else we do not need parenthesis *)
	| _ -> fun x -> x
      ) (
	match filter_explicit args with
	  | arg1::arg2::[] ->
	    let arg1 = pattern2token ctxt arg1 (InNotation (Infix (myprio, myassoc), 1)) in
	    let arg2 = pattern2token ctxt arg2 (InNotation (Infix (myprio, myassoc), 2)) in
	    let te = Verbatim s in
	    Box (intercalate (Space 1) [arg1; te; arg2])
	  | _ -> raise (Failure "pattern2token, App infix case: irrefutable patten")
       )
    (* the case for Prefix *)
    | PApp (Symbol (s, (Prefix myprio)), args, _) when List.length (filter_explicit args) = 1 ->
      (* we put parenthesis when
	 - as the head or argument of an application
	 - in a postfix notation more binding than us
	 - in an alias
      *)
      (match p with
	| InArg Explicit -> withParen
	| InApp -> withParen
	| InAlias -> withParen
	| InNotation (Postfix i, _) when i > myprio -> withParen
	| _ -> fun x -> x
      ) (
	match filter_explicit args with
	  | arg::[] ->
	    let arg = pattern2token ctxt arg (InNotation (Prefix myprio, 1)) in
	    let te = Verbatim s in
	    Box (intercalate (Space 1) [te; arg])
	  | _ -> raise (Failure "pattern2token, App prefix case: irrefutable patten")
       )

    (* the case for Postfix *)
    | PApp (Symbol (s, (Postfix myprio)), args, _) when List.length (filter_explicit args) = 1 ->
      (* we put parenthesis when
	 - as the head or argument of an application
	 - in a prefix notation more binding than us
	 - in an alias
      *)
      (match p with
	| InArg Explicit -> withParen
	| InApp -> withParen
	| InNotation (Prefix i, _) when i > myprio -> withParen
	| InAlias -> withParen
	| _ -> fun x -> x
      ) (
	match filter_explicit args with
	  | arg::[] ->
	    let arg = pattern2token ctxt arg (InNotation (Postfix myprio, 1)) in
	    let te = Verbatim s in
	    Box (intercalate (Space 1) [arg; te])
	  | _ -> raise (Failure "term2token, App postfix case: irrefutable patten")
       )

    (* general case *)
    | PApp (s, args, _) ->
      (* we only embed in parenthesis if
	 - we are an argument of an application
	 - we are in a notation
      *)
      (match p with
	| InArg Explicit -> withParen
	| InNotation _ -> withParen
	| InAlias -> withParen
	| _ -> fun x -> x
      ) (
	let args = List.map (fun te -> pattern2token ctxt te (InArg Explicit)) (filter_explicit args) in
	let s = symbol2string s in
	Box (intercalate (Space 1) (Verbatim s::args))
       )


(* make a string from a term *)
let term2string (ctxt: context) (te: term) : string =
  let token = term2token ctxt te Alone in
  let box = token2box token 80 2 in
  box2string box

(* pretty printing for errors *)
let pos2token (p: pos) : token =
  let startp, endp = p in
  Box [Verbatim (string_of_int (fst startp)); 
       Verbatim ":"; 
       Verbatim (string_of_int (snd startp)); 
       Verbatim "-"; 
       Verbatim (string_of_int (fst endp)); 
       Verbatim ":"; 
       Verbatim (string_of_int (snd endp)); 
      ]
    

let rec error2token (err: doudou_error) : token =
  match err with
    | NegativeIndexBVar i -> Verbatim "bvar as a negative index"
    | Unshiftable_term (te, level, delta) -> Verbatim "Cannot shift a term"
    | ErrorPosPair (Some pos1, Some pos2, err) ->
      Box [
	pos2token pos1; Space 1; Verbatim "/"; Space 1; pos2token pos2; Space 1; Verbatim ":"; Newline;
	error2token err
      ]
    | ErrorPosPair (None, Some pos2, err) ->
      Box [
	pos2token pos2; Space 1; Verbatim ":"; Newline;
	error2token err
      ]
    | ErrorPosPair (Some pos1, None, err) ->
      Box [
	pos2token pos1; Space 1; Verbatim ":"; Newline;
	error2token err
      ]
    | ErrorPosPair (None, None, err) ->
      error2token err
    | ErrorPos (pos, err) ->
      Box [
	pos2token pos; Space 1; Verbatim ":"; Newline;
	error2token err
      ]
    | UnknownUnification (ctxt, te1, te2) | NoUnification (ctxt, te1, te2) ->
      Box [
	Verbatim "Cannot unify:"; Newline;
	term2token ctxt te1 Alone; Newline;
	  term2token ctxt te2 Alone;
      ]
    | NoMatchingPattern (ctxt, p, te) ->
      Box [
	Verbatim "Cannot unify:"; Newline;
	pattern2token ctxt p Alone; Newline;
	  term2token ctxt te Alone;
      ]
    | CannotInfer (ctxt, te, err) ->
      Box [
	Verbatim "cannot infer type for:"; Space 1;
	term2token ctxt te Alone; Newline;
	Verbatim "reason:"; Newline;
	error2token err
      ]
    | CannotTypeCheck (ctxt, te, inferedty, ty, err) ->
      Box [
	Verbatim "the term:"; Space 1;
	term2token ctxt te Alone; Newline;
	Verbatim "of infered type:"; Space 1;
	term2token ctxt inferedty Alone; Newline;
	Verbatim "cannot be typecheck with type:"; Space 1;
	term2token ctxt ty Alone; Newline;
	Verbatim "reason:"; Newline;
	error2token err
      ]

    | _ -> Verbatim "Internal error"

(* make a string from an error *)
let error2string (err: doudou_error) : string =
  let token = error2token err in
  let box = token2box token 80 2 in
  box2string box


(**********************************)
(* parser (lib/parser.ml version) *)
(**********************************)

let with_start_pos (startp: (int * int)) (p: 'a parsingrule) : 'a parsingrule =
  fun pb ->
    let curp = cur_pos pb in
    if (snd startp <= snd curp) then raise NoMatch;
    p pb

let with_pos (p: 'a parsingrule) : ('a * pos) parsingrule =
  fun pb ->
    let startp = cur_pos pb in
    let res = p pb in
    let endp = cur_pos pb in
    (res, (startp, endp))

let doudou_keywords = ["Type"]

open Str;;

let name_parser : name parsingrule = applylexingrule (regexp "[a-zA-Z][a-zA-Z0-9]*", 
						      fun (s:string) -> 
							if List.mem s doudou_keywords then raise NoMatch else s
)

let parse_avar : unit parsingrule = applylexingrule (regexp "_", 
						     fun (s:string) -> ()
)

let parse_symbol_name : symbol parsingrule = 
  let f = 
    applylexingrule (regexp "+|-|*|/|&|@", 
		     fun (s:string) -> s)
  in 
  (* no fix *)
  tryrule (fun pb ->
    let () = whitespaces pb in
    let () = word "[" pb in
    let s = f pb in
    let () = word "]" pb in
    let () = whitespaces pb in
    Symbol (s, Nofix)
  )
  (* prefix *)
  <|> tryrule (fun pb ->
    let () = whitespaces pb in
    let () = word "[" pb in
    let s = f pb in
    let () = word ")" pb in
    let () = whitespaces pb in
    Symbol (s, Prefix 0)
  )
  (* infix *)
  <|> tryrule (fun pb ->
    let () = whitespaces pb in
    let () = word "(" pb in
    let s = f pb in
    let () = word ")" pb in
    let () = whitespaces pb in
    Symbol (s, Infix (0, NoAssoc))
  )
  (* postfix *)
  <|> tryrule (fun pb ->
    let () = whitespaces pb in
    let () = word "(" pb in
    let s = f pb in
    let () = word "]" pb in
    let () = whitespaces pb in
    Symbol (s, Postfix 0)
  )
  (* just a name *)
  <|> tryrule (fun pb ->
    let () = whitespaces pb in
    let n = name_parser pb in
    let () = whitespaces pb in
    Name n
  )


let parse_symbol (defs: defs) : symbol parsingrule =
  fun pb -> 
    let res = fold_stop (fun () s ->
      try
	let () = tryrule (word (symbol2string s)) pb in
	Right s
      with
	| NoMatch -> Left ()
    ) () defs.hist in
    match res with
      | Left () -> raise NoMatch
      | Right s -> s
	

let create_opparser_term (defs: defs) (primary: term parsingrule) : term opparser =
  let res = { primary = primary;
	      prefixes = Hashtbl.create (List.length defs.hist);
	      infixes = Hashtbl.create (List.length defs.hist);
	      postfixes = Hashtbl.create (List.length defs.hist);
	    } in
  let _ = List.map (fun s -> 
    match s with
      | Name _ -> ()
      | Symbol (n, Nofix) -> ()
      | Symbol (n, Prefix i) -> Hashtbl.add res.prefixes n (i, fun te -> App (Cste s, [te, Explicit]))
      | Symbol (n, Infix (i, a)) -> Hashtbl.add res.infixes n (i, a, fun te1 te2 -> App (Cste s, [te1, Explicit; te2, Explicit]))
      | Symbol (n, Postfix i) -> Hashtbl.add res.postfixes n (i, fun te -> App (Cste s, [te, Explicit]))
  ) defs.hist in
  res

let create_opparser_pattern (defs: defs) (primary: pattern parsingrule) : pattern opparser =
  let res = { primary = primary;
	      prefixes = Hashtbl.create (List.length defs.hist);
	      infixes = Hashtbl.create (List.length defs.hist);
	      postfixes = Hashtbl.create (List.length defs.hist);
	    } in
  let _ = List.map (fun s -> 
    match s with
      | Name _ -> ()
      | Symbol (n, Nofix) -> ()
      | Symbol (n, Prefix i) -> Hashtbl.add res.prefixes n (i, fun te -> PApp (s, [te, Explicit], AVar))
      | Symbol (n, Infix (i, a)) -> Hashtbl.add res.infixes n (i, a, fun te1 te2 -> PApp (s, [te1, Explicit; te2, Explicit], AVar))
      | Symbol (n, Postfix i) -> Hashtbl.add res.postfixes n (i, fun te -> PApp (s, [te, Explicit], AVar))
  ) defs.hist in
  res

(* these are the whole term set 
   - term_lvlx "->" term
*)
let rec parse_term (defs: defs) (leftmost: (int * int)) (pb: parserbuffer) : term = begin
  tryrule (fun pb ->
    let () = whitespaces pb in
    let startpos = cur_pos pb in
    let (names, ty, nature) = parse_impl_lhs defs leftmost pb in
    let () = whitespaces pb in
    let () = word "->" pb in
    let () = whitespaces pb in
    let body = parse_term defs leftmost pb in
    let endpos = cur_pos pb in
    let () = whitespaces pb in
    SrcInfo ((startpos, endpos), build_impl names ty nature body)
  ) 
  <|> parse_term_lvl0 defs leftmost
end pb

and parse_impl_lhs (defs: defs) (leftmost: (int * int)) (pb: parserbuffer) : (symbol list * term * nature) = begin
  (* first case 
     with paren
  *)
  tryrule (paren (fun pb ->
    let names = separatedBy name_parser whitespaces pb in
    let () = whitespaces pb in
    let () = word "::" pb in
    let () = whitespaces pb in
    let ty = parse_term defs leftmost pb in
    (List.map (fun n -> Name n) names, ty, Explicit)
   )
  )
  (* or the same but with bracket *)
  <|> tryrule (bracket (fun pb ->
    let names = separatedBy name_parser whitespaces pb in
    let () = whitespaces pb in
    let () = word "::" pb in
    let () = whitespaces pb in
    let ty = parse_term defs leftmost pb in
    (List.map (fun n -> Name n) names, ty, Implicit)
  )
  )
  (* or just a type -> anonymous arguments *)
  <|> (fun pb -> 
    let ty = parse_term_lvl0 defs leftmost pb in
    ([Symbol ("_", Nofix)], ty, Explicit)        
  )
  <|> (fun pb -> 
    let ty = paren (parse_term_lvl0 defs leftmost) pb in
    ([Symbol ("_", Nofix)], ty, Explicit)        
  )
  <|> (fun pb -> 
    let ty = bracket (parse_term_lvl0 defs leftmost) pb in
    ([Symbol ("_", Nofix)], ty, Implicit)        
  )
end pb

(* this is operator-ed terms with term_lvl1 as primary
*)
and parse_term_lvl0 (defs: defs) (leftmost: (int * int)) (pb: parserbuffer) : term = begin
  let myp = create_opparser_term defs (parse_term_lvl1 defs leftmost) in
  opparse myp
end pb

(* this is term resulting for the application of term_lvl2 *)
and parse_term_lvl1 (defs: defs) (leftmost: (int * int)) (pb: parserbuffer) : term = begin
  fun pb -> 
    (* first we parse the application head *)
    let startpos = cur_pos pb in
    let head = parse_term_lvl2 defs leftmost pb in    
    let () = whitespaces pb in
    (* then we parse the arguments *)
    let args = separatedBy (
      fun pb ->
      parse_arguments defs leftmost pb
    ) whitespaces pb in
    let endpos = cur_pos pb in
    match args with
      | [] -> head
      | _ -> 
	SrcInfo ((startpos, endpos), App (head, args))
end pb

(* arguments: term_lvl2 with possibly brackets *)
and parse_arguments (defs: defs) (leftmost: (int * int)) (pb: parserbuffer) : (term * nature) = begin
  (fun pb -> 
    let te = bracket (parse_term_lvl2 defs leftmost) pb in
    (te, Implicit)
  )
  <|> (fun pb -> 
    let te = parse_term_lvl2 defs leftmost pb in
    (te, Explicit)
  )
end pb

(* these are the most basic terms + top-level terms in parenthesis *)
and parse_term_lvl2 (defs: defs) (leftmost: (int * int)) (pb: parserbuffer) : term = begin
  (fun pb -> 
    let () = whitespaces pb in
    let (), pos = with_pos (word "Type") pb in
    let () = whitespaces pb in
    SrcInfo (pos, Type)
  ) 
  <|> (fun pb ->
    let () =  whitespaces pb in
    let (), pos = with_pos parse_avar pb in
    let () =  whitespaces pb in
    SrcInfo (pos, AVar)
  ) 
  <|> (fun pb ->
    let () = whitespaces pb in
    let () = word "\\" pb in    
    let eqs = separatedBy (fun pb ->
      let () = whitespaces pb in
      let patterns = separatedBy (parse_pattern_arguments defs leftmost) whitespaces pb in
      let () =  whitespaces pb in
      let () = word "->" pb in
      let () =  whitespaces pb in
      let body = parse_term defs leftmost pb in
      let () =  whitespaces pb in
      build_destructwith patterns body
    ) (word "|") pb in
    List.fold_left (fun (DestructWith acc) (DestructWith eqs) ->
      DestructWith (acc @ eqs)
    ) (DestructWith []) eqs    
  ) 
  <|> (fun pb -> 
    let () =  whitespaces pb in
    let s, pos = with_pos parse_symbol_name pb in
    let () =  whitespaces pb in    
    SrcInfo (pos, TName s)
  )
  <|> (paren (parse_term defs leftmost))
end pb

and parse_pattern (defs: defs) (leftmost: (int * int)) (pb: parserbuffer) : pattern = begin
  let myp = create_opparser_pattern defs (parse_pattern_lvl1 defs leftmost) in
  opparse myp
end pb

and parse_pattern_lvl1 (defs: defs) (leftmost: (int * int)) (pb: parserbuffer) : pattern = begin
  fun pb -> 
    (* first we parse the application head *)
    let s = parse_symbol defs pb in    
    let () = whitespaces pb in
    (* then we parse the arguments *)
    let args = separatedBy (
      fun pb ->
	parse_pattern_arguments defs leftmost pb
    ) whitespaces pb in
    match args with
      | [] -> PCste s
      | _ -> PApp (s, args, AVar)	  
end pb

and parse_pattern_arguments (defs: defs) (leftmost: (int * int)) (pb: parserbuffer) : pattern * nature = begin
  (fun pb -> 
    let te = bracket (parse_pattern_lvl2 defs leftmost) pb in
    (te, Implicit)
  )
  <|> (fun pb -> 
    let te = parse_pattern_lvl2 defs leftmost pb in
    (te, Explicit)
  )
end pb
  
and parse_pattern_lvl2 (defs: defs) (leftmost: (int * int)) (pb: parserbuffer) : pattern = begin
  (fun pb -> 
    let () = whitespaces pb in
    let () = word "Type" pb in
    let () = whitespaces pb in
    PType
  ) 
  <|> (fun pb ->
    let () =  whitespaces pb in
    let () = parse_avar pb in
    let () =  whitespaces pb in
    PAVar AVar
  ) 
  <|> tryrule (fun pb ->
    let () =  whitespaces pb in
    let s = parse_symbol defs pb in
    let () =  whitespaces pb in
    PCste s
  )
  <|> tryrule (fun pb ->
    let () =  whitespaces pb in
    let name = name_parser pb in
    let () = word "@" pb in
    let p = parse_pattern defs leftmost pb in
    PAlias (name, p, AVar)
  )
  <|> (fun pb -> 
    let () =  whitespaces pb in
    let name = name_parser pb in
    let () =  whitespaces pb in    
    PVar (name, AVar)
  )
  <|> (paren (parse_pattern defs leftmost))
end pb

type definition = Signature of symbol * term
		  | Equation of symbol * (pattern * nature list) * term

let rec parse_definition (defs: defs) (leftmost: int * int) : definition parsingrule =
  tryrule (fun pb ->
    let () = whitespaces pb in
    let s = parse_symbol_name pb in
    let () = whitespaces pb in
    (* here we should have the property *)
    let () = whitespaces pb in
    let () = word "::" pb in
    let () = whitespaces pb in
    let ty = parse_term defs leftmost pb in
    Signature (s, ty)
  )
  

(******************************)
(*        tests               *)
(******************************)

(* pretty printer *)

let zero = Cste (Name "0")
let splus = (Symbol ("+", Infix (30, LeftAssoc)))
let plus = Cste splus
let minus = Cste (Symbol ("-", Infix (30, LeftAssoc)))
let mult = Cste (Symbol ("*", Infix (40, LeftAssoc)))
let div = Cste (Symbol ("/", Infix (40, LeftAssoc)))
let colon = Cste (Symbol (";", Infix (20, RightAssoc)))
let andc = Cste (Symbol ("&", Postfix 20))
let neg = Cste (Symbol ("-", Prefix 50))

let nat = (Cste (Name "nat"))

let asymb = Symbol ("_", Nofix)

let avar = Cste asymb

let _ = printf "%s\n" (term2string empty_context zero)
let _ = printf "%s\n" (term2string empty_context plus)
let _ = printf "%s\n" (term2string empty_context andc)
let _ = printf "%s\n" (term2string empty_context neg)
let _ = printf "%s\n" (term2string empty_context (App (andc, [App (mult, [zero, Explicit; zero, Explicit]), Explicit])))
let _ = printf "%s\n" (term2string empty_context (App (neg, [App (mult, [zero, Explicit; zero, Explicit]), Explicit])))

let _ = printf "%s\n" (term2string empty_context (
  Impl ((asymb, Impl ((asymb, nat, Explicit), Impl ((asymb, nat, Implicit), nat)), Implicit), Impl ((Name "prout", nat, Explicit), nat))
)
)

let _ = printf "%s\n" (term2string empty_context (
  DestructWith [((PVar ("x", avar), Explicit), DestructWith [((PVar ("y", avar), Implicit), App (plus, [TVar 0, Explicit; TVar 1, Explicit]))])]
)
)

let _ = printf "%s\n" (term2string empty_context (
  DestructWith [
    (
      (PApp (splus, [PVar ("x", avar), Explicit; PVar ("z", avar), Explicit], Cste asymb), Explicit), 
      DestructWith [
	((PVar ("y", avar), Implicit), 
	 App (plus, [TVar 0, Explicit; TVar 1, Explicit])
	)
      ]
    )
  ]
)
)

(******************************************)
(*        tests with parser               *)
(******************************************)

open Stream

let process_term (defs: defs) (ctxt: context ref) (s: string) : unit =
    (* we set the parser *)
    let lines = stream_of_string s in
    let pb = build_parserbuffer lines in
    let pos = cur_pos pb in
    (* we save the context *)
    let saved_ctxt = !ctxt in
    try
      let te = parse_term defs pos pb in
      let te, ty = typeinfer defs ctxt te in
      printf "%s::%s\n" (term2string !ctxt te) (term2string !ctxt ty)
    with
      | NoMatch -> 
	printf "parsing error:\n%s\n" (errors2string pb)
      | DoudouException err -> 
	(* we restore the context *)
	ctxt := saved_ctxt;
	printf "typechecking error:\n%s\n" (error2string err)

let ctxt = ref empty_context

let _ = process_term empty_defs ctxt "Type"

(*let _ = process_term empty_defs ctxt "\\ x -> x | y -> y | z -> z"*)

let defs = ref empty_defs

let process_definition (defs: defs ref) (ctxt: context ref) (s: string) : unit =
    (* we set the parser *)
    let lines = stream_of_string s in
    let pb = build_parserbuffer lines in
    let pos = cur_pos pb in
    (* we save the context and the defs *)
    let saved_ctxt = !ctxt in
    let saved_defs = !defs in
    try
      let def = parse_definition !defs pos pb in
      match def with
	| Signature (s, ty) ->
	  let ty, _ = typecheck !defs ctxt ty Type in
	  Hashtbl.add !defs.store (symbol2string s) (s, ty, None);
	  defs := {!defs with hist = s::!defs.hist  };
	  printf "%s :: %s\n" (symbol2string s) (term2string !ctxt ty)
    with
      | NoMatch -> 
	printf "parsing error:\n%s\n" (errors2string pb)
      | DoudouException err -> 
	(* we restore the context and defs *)
	ctxt := saved_ctxt;
	defs := saved_defs;
	printf "typechecking error:\n%s\n" (error2string err)

let _ = process_definition defs ctxt "Bool :: Type"
let _ = process_definition defs ctxt "True :: Bool"
let _ = process_definition defs ctxt "False :: Bool"
let _ = process_definition defs ctxt "b :: True"
let _ = process_definition defs ctxt "List :: Type -> Type"
