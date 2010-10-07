(********************************************************
   This file is part of jStar
	src/prover/clogic.ml
   Release
        $Release$
   Version
        $Rev$
   $Copyright$

   jStar is distributed under a BSD license,  see,
      LICENSE.txt
 ********************************************************)
open Backtrack
open Congruence
open Cterm
open Format
open Misc
open Multiset
open Printing
open Psyntax

exception Success
exception Failed
exception Assm_Contradiction

module RMSet = MultisetImpl(
  struct
    type t = string * Cterm.term_handle
    let compare = compare
  end
)

type multiset = RMSet.multiset

module SMSet = MultisetImpl(
  struct
    type t = string * (Psyntax.args list)
    let compare = compare
  end
)

type syntactic_form =
  {
   sspat : SMSet.multiset;
   splain : SMSet.multiset;
   sdisjuncts : (syntactic_form * syntactic_form) list;
   seqs : (Psyntax.args * Psyntax.args) list;
   sneqs : (Psyntax.args * Psyntax.args) list;
  }


type formula =
  {
    spat : RMSet.multiset;
    plain : RMSet.multiset;
    disjuncts : (formula * formula) list;
    eqs : (term_handle * term_handle) list;
    neqs : (term_handle * term_handle) list;
  }

type ts_formula =
  {
    ts : Cterm.term_structure;
    form : formula;
    cache_sform : syntactic_form option ref;
  }

let mk_ts_form ts form =
  {ts = ts; form = form; cache_sform = ref None}

let break_ts_form ts_form =
  ts_form.ts, ts_form.form

let kill_var ts_form v =
  {ts_form with ts = Cterm.kill_var ts_form.ts v}

let update_var_to ts_form v e =
  {ts_form with ts = Cterm.update_var_to ts_form.ts v e}

(* {{{ pretty printing
 * See 
 *   http://rgrig.blogspot.com/2010/09/certain-type-of-pretty-printing-in.html
 * for an explanation of the basic idea.  *)
(* {{{ printing of atomic formulas *)
(* TODO(rgrig): What's a better name for RMSet.t and SMSet.t? *)
let pp_rmset_element prefix pp_term ppf (s, t) =
  fprintf ppf "@[%s%s%a@]" prefix s pp_term t

let pp_smset_element prefix ppf (n, args) =
  fprintf ppf "@[%s%s(%a)@]" prefix n string_args_list args

(* }}} *)
(* {{{ printing for [formula], [syntactic_form], and [ts_form] *)
(* NOTE: The pattern match on formula is meant to cause errors if
  * new fields are added to type [formula]. *)
let rec pp_formula' pp_term pp ppf first 
  {spat=spat; plain=plain; disjuncts=disjuncts; eqs=eqs; neqs=neqs } =
    let first = 
      List.fold_left (pp.separator (pp_eq pp_term) ppf) first eqs in
    let first = 
      List.fold_left (pp.separator (pp_neq pp_term) ppf) first neqs in
    let first = 
      RMSet.fold (pp.separator (pp_rmset_element "" pp_term) ppf) first spat in
    let first = 
      RMSet.fold (pp.separator (pp_rmset_element "!" pp_term) ppf) first plain 
    in
      List.fold_left 
        (pp.separator (pp_disjunct (pp_formula pp_term)) ppf) first disjuncts
and pp_formula pp_term = pp_whole (pp_formula' pp_term) pp_star

let rec pp_syntactic_form' pp ppf first 
  {sspat=sspat; splain=splain; sdisjuncts=sdisjuncts; seqs=seqs; sneqs=sneqs} =
    let first = 
      List.fold_left (pp.separator (pp_eq string_args) ppf) first seqs in
    let first = 
      List.fold_left (pp.separator (pp_neq string_args) ppf) first sneqs in
    let first = 
      SMSet.fold (pp.separator (pp_smset_element "") ppf) first sspat in
    let first = 
      SMSet.fold (pp.separator (pp_smset_element "!") ppf) first splain 
    in
      List.fold_left 
        (pp.separator (pp_disjunct pp_syntactic_form) ppf) first sdisjuncts
and pp_syntactic_form ppf sform = pp_whole pp_syntactic_form' pp_star ppf sform

let pp_ts_formula' pp ppf first {ts=ts; form=form; cache_sform=_} =
  let first = Cterm.pp_ts' pp ppf first ts in
  pp_formula' (pp_c ts) pp ppf first form

let pp_ts_formula = pp_whole pp_ts_formula' pp_star

(* }}} *)
(* pretty printing }}} *)

let conjunction form1 form2 : formula =
  {
  spat = RMSet.union form1.spat form2.spat;
  plain = RMSet.union form1.plain form2.plain;
  disjuncts = form1.disjuncts @ form2.disjuncts;
  eqs = form1.eqs @ form2.eqs;
  neqs = form1.neqs @ form2.neqs;
}

let disjunction form1 form2 : formula =
  {
  spat = RMSet.empty;
  plain = RMSet.empty;
  disjuncts = [(form1,form2)];
  eqs =[];
  neqs = [];
}

let empty : formula =
  {
  spat = RMSet.empty;
  plain = RMSet.empty;
  disjuncts = [];
  eqs = [];
  neqs = [];
}

let false_sform =
  {
  sspat = SMSet.empty;
  splain = SMSet.lift_list [("@False",[])];
  sdisjuncts = [];
  seqs = [];
  sneqs = [];
}

let is_sempty s =
  s.sspat = SMSet.empty &&
  s.splain = SMSet.empty &&
  s.sdisjuncts = [] &&
  s.seqs = [] &&
  s.sneqs = []

let truth = empty

let is_true form =
  form.spat = RMSet.empty
    && form.plain = RMSet.empty
    && form.disjuncts = []
    && form.eqs = []
    && form.neqs = []


let add_eqs_t_list fresh eqs ts : term_structure =
  List.fold_left (fun ts (x,y) ->
    try
      make_equal_t fresh ts x y
    with Contradiction ->
      fprintf !(Debug.proof_dump) "Trying to make %a and %a equal failed" string_args x string_args y;
      raise Contradiction
      ) ts eqs

let add_neqs_t_list fresh neqs ts : term_structure =
  List.fold_left (fun ts (x,y) ->
    try
      make_not_equal_t fresh ts x y
    with Contradiction ->
      fprintf !(Debug.proof_dump) "Trying to make %a and %a not equal failed" string_args x string_args y;
      raise Contradiction
      ) ts neqs

let add_eqs_list eqs ts : term_structure =
  List.fold_left (fun ts (x,y) -> make_equal ts x y) ts eqs

let add_neqs_list neqs ts : term_structure =
  List.fold_left (fun ts (x,y) -> make_not_equal ts x y) ts neqs


  (* As multiple term_handles might be equal,
     we have to use a comparison based only on the predicate name.
     The sorting means predicates with the same name will be next
     to each other. *)
let intersect_with_ts ts rem_snd set1 set2 =
  let loose_compare a b = compare (fst a) (fst b) in
  let equal (an,ar) (bn,br) = an=bn && equal ts ar br in
  let rec match_same rem_snd set1 set2 intersect count =
    if RMSet.has_more set1 && RMSet.has_more set2 then
      let c1,nset1 = RMSet.remove set1 in
      let c2,nset2 = RMSet.remove set2 in
      if loose_compare c1 c2 = 0 then
	if equal c1 c2 then
	  let nset2 = (if rem_snd then nset2 else set2) in
	  match_same rem_snd nset1 (RMSet.back nset2 count) (c2::intersect) 0
	else
	    (* Not a match, try next. *)
	  match_same rem_snd set1 (RMSet.next set2) intersect (count+1)
      else if loose_compare c1 c2 < 0 then
	  (* First set is a low one, so skip element,
	     reverse second set over similar elements incase next element is same class*)
	match_same rem_snd (RMSet.next set1) (RMSet.back set2 count) intersect 0
      else
	  (* Second set has lowest element, so skip element *)
	match_same rem_snd set1 (RMSet.next set2) intersect 0
    else
	(* No more left to match *)
      (RMSet.lift_list intersect, RMSet.restart set1, RMSet.restart set2)
  in
  match_same rem_snd set1 set2 [] 0



let rec normalise ts form : formula * term_structure =
(*  printf "Normalising formula : %a @\n" pp_ts_form  {ts=ts;form=form};*)
  let rec f nform ts disj =
    match disj with
      [] -> nform,ts
    | (f1,f2)::disj ->
	let f1o =
	  try
	    let ts1 = add_eqs_list f1.eqs ts in
	    let ts1 = add_neqs_list f1.neqs ts1 in
	    let f1,ts1 = normalise ts1 f1 in
	    Some (f1,ts1)
	  with Contradiction ->
(*	    printf "Contradiction left@\n";*)
	    None in
	let f2o =
	  try
	    let ts2 = add_eqs_list f2.eqs ts in
	    let ts2 = add_neqs_list f2.neqs ts2 in
	    let f2,ts2 = normalise ts2 f2 in
	    Some (f2,ts2)
	  with Contradiction ->
(*	    printf "Contradiction right@\n";*)
	    None in
	match f1o,f2o with
	  None,None -> raise Contradiction
	| Some (form,ts'), None
	| None, Some (form,ts') ->
	    fprintf !(Debug.proof_dump) 
              "Disjunct eliminated! Remaining disjunct:@ %a@\n" 
              (pp_formula (pp_c ts)) form;
	    let nform = (conjunction form nform) in
	    f nform
	      ts'
	      disj
	| Some (f1,_),Some (f2,_) ->
	    (* TODO intersect is too discriminating *)
	    let s,s1,s2 = intersect_with_ts ts true f1.spat f2.spat in
	    let p,p1,p2 = intersect_with_ts ts true f1.plain f2.plain in
	    let f1 = {f1 with spat=s1;plain=p1} in
	    let f2 = {f2 with spat=s2;plain=p2} in
	    f
	      {nform with
	       spat = RMSet.union s nform.spat;
	       plain = RMSet.union p nform.plain;
	       disjuncts =
	       if is_true(f1) || is_true(f2) then
		 nform.disjuncts
	       else
		 ((f1,f2)::nform.disjuncts)
	     }
	      ts
	      disj
  in
  let form,ts = f {form with disjuncts=[]} ts form.disjuncts in
(*  printf "Normalised formula : %a @\n" pp_ts_form  {ts=ts;form=form};*)
  form,ts




let rec convert_to_inner (form : Psyntax.pform) : syntactic_form =
  let convert_atomic_to_inner (sspat,splain,sdisj,seqs,sneqs) pat =
    match pat with
      P_EQ (a1,a2) -> sspat, splain,sdisj,(a1,a2)::seqs, sneqs
    | P_NEQ (a1,a2) -> sspat, splain,sdisj,seqs, (a1,a2)::sneqs
    | P_PPred (name, al) -> sspat, ((name, al)::splain),sdisj,seqs,sneqs
    | P_SPred (name, al) -> ((name,al)::sspat), splain,sdisj,seqs,sneqs
    | P_Wand _ | P_Septract _
    | P_Garbage -> ("@Garbage",[])::sspat, splain,sdisj,seqs,sneqs
    | P_False -> sspat, (("@False", [])::splain),sdisj,seqs,sneqs
    | P_Or(f1,f2) ->
	let f1 = convert_to_inner f1 in
	let f2 = convert_to_inner f2 in
	sspat, splain, (f1,f2)::sdisj, seqs, sneqs
  in
  let (sspat,splain,sdisj,seqs,sneqs) = List.fold_left convert_atomic_to_inner ([],[],[],[],[]) form in
  {
   sspat = SMSet.lift_list sspat;
   splain = SMSet.lift_list splain;
   sdisjuncts = sdisj;
   seqs = seqs;
   sneqs = sneqs;
 }

let smset_to_list fresh a ts =
  let a = SMSet.restart a in
  let rec inner a rs ts =
    if SMSet.has_more a then
      let (n,tl),a = SMSet.remove a in
      let c,ts = add_tuple fresh tl ts in
      inner a ((n,c)::rs) ts
    else
      rs, ts
  in inner a [] ts
  

let rec add_pair_list fresh xs ts rs =
  match xs with
    [] -> rs,ts
  | (a,b) ::xs ->
      let c1,ts = add_term fresh a ts in
      let c2,ts = add_term fresh b ts in
      add_pair_list fresh xs ts ((c1,c2)::rs)
      
      
(* TODO: Will convert eqs into ts for or which is wrong. *)
let rec convert_sf fresh (ts :term_structure) (sf : syntactic_form) : formula * term_structure =
  let spat, ts = smset_to_list fresh sf.sspat ts in
  let plain, ts = smset_to_list fresh sf.splain ts in
  let disj, ts  = convert_sf_pair_list fresh ts sf.sdisjuncts [] in
  let ts = add_eqs_t_list fresh sf.seqs ts in
  let ts = add_neqs_t_list fresh sf.sneqs ts in
  {spat = RMSet.lift_list spat; plain = RMSet.lift_list plain; disjuncts = disj;eqs=[];neqs=[]}, ts
and convert_sf_without_eqs
 fresh (ts :term_structure) (sf : syntactic_form) : formula * term_structure =
  let spat, ts = smset_to_list fresh sf.sspat ts in
  let plain, ts = smset_to_list fresh sf.splain ts in
  let disj, ts  = convert_sf_pair_list fresh ts sf.sdisjuncts [] in
  let eqs,ts = add_pair_list fresh sf.seqs ts [] in
  let neqs,ts = add_pair_list fresh sf.sneqs ts [] in
  {spat = RMSet.lift_list spat; plain = RMSet.lift_list plain; disjuncts = disj;
  eqs=eqs;neqs=neqs}, ts
and convert_sf_pair_list
    fresh (ts :term_structure)
    (sf : (syntactic_form * syntactic_form) list)
    (rs : (formula * formula) list)
  : ((formula * formula) list) * term_structure =
  match sf with
    [] -> rs,ts
  | (x,y)::sf ->
      let x,ts = convert_sf_without_eqs fresh ts x in
      let y,ts = convert_sf_without_eqs fresh ts y in
      convert_sf_pair_list fresh ts sf ((x,y)::rs)



(* convert to a formula with all pattern variables converted to ground *)
let smset_to_list_ground a ts =
  let a = SMSet.restart a in
  let rec inner a rs ts =
    if SMSet.has_more a then
      let (n,tl),a = SMSet.remove a in
      let c,ts = ground_pattern_tuple tl ts in
      inner a ((n,c)::rs) ts
    else
      rs, ts
  in inner a [] ts

let rec convert_ground (ts :term_structure) (sf : syntactic_form) : formula * term_structure =
  assert (sf.sdisjuncts = []);  (* don't want disjuncts in an SMT pattern *)
  assert (sf.sspat = SMSet.empty); 
  let plain, ts = smset_to_list_ground sf.splain ts in
  let eqs, ts = List.fold_left (fun (eqs,ts) (x,y) -> let cx,ts = ground_pattern x ts in let cy,ts = ground_pattern y ts in ((cx,cy)::eqs,ts)) ([],ts) sf.seqs in  
  let neqs, ts = List.fold_left (fun (neqs,ts) (x,y) -> let cx,ts = ground_pattern x ts in let cy,ts = ground_pattern y ts in ((cx,cy)::neqs,ts)) ([],ts) sf.sneqs in  
  {spat = RMSet.empty; plain = RMSet.lift_list plain; disjuncts = []; eqs=eqs; neqs=neqs}, ts


let conjoin fresh (f : ts_formula) (sf : syntactic_form) =
  let nf,ts = convert_sf fresh f.ts sf in
  let nf = conjunction nf f.form in
  {ts = ts; form = nf; cache_sform = ref None}


let make_syntactic ts_form =
  let ts,form = break_ts_form ts_form in
  let eqs = Cterm.get_eqs ts in
  let neqs = Cterm.get_neqs ts in

  let rec form_to_syntax form =
    let convert_tuple r =
      match get_term ts r with
	Psyntax.Arg_op("tuple",al) -> al
      | _ -> assert false in
    let convert_pair = lift_pair (get_term ts) in
    let eqs = List.map convert_pair form.eqs in
    let neqs = List.map convert_pair form.neqs in
    let sspat_list = RMSet.map_to_list form.spat (fun (name,i)->(name,convert_tuple i)) in
    let splain_list = RMSet.map_to_list form.plain (fun (name,i)->(name,convert_tuple i)) in
    let disjuncts = List.map (lift_pair form_to_syntax) form.disjuncts in
    {seqs= eqs;
      sneqs=neqs;
      sspat = SMSet.lift_list sspat_list;
      splain = SMSet.lift_list splain_list;
      sdisjuncts = disjuncts}
  in
  let sform = form_to_syntax form in
  {sform with
    seqs = sform.seqs @ eqs;
    sneqs = sform.sneqs @ neqs}


(* Heuristic abstraction on syntactic form that eliminates existentials which are not in the spatial part *)
let eliminate_existentials syn_form =
  (* finds existentials in the spatial part *)
  let rec find_ev_sp syn =
    if syn.sdisjuncts = [] then
      SMSet.fold_to_list syn.sspat (fun t vs -> 
        vs_union (ev_args_list (snd t) vs_empty) vs) vs_empty
    else begin
      List.fold_left (fun vs (s1, s2) -> 
        vs_union (vs_union (find_ev_sp s1) (find_ev_sp s2)) vs
      ) vs_empty syn.sdisjuncts   
    end
  in
  (* finds existentials in equalities and inequalities *)
  let rec find_ev_eq_neq syn vset =
    let get_evs a1 a2 =
      if (vs_is_empty (vs_inter vset (ev_args a1 vs_empty)) <> true ||
        vs_is_empty (vs_inter vset (ev_args a2 vs_empty)) <> true) then
        vs_union vset (vs_union (ev_args a1 vs_empty) (ev_args a2 vs_empty))
      else
        vset
    in
    if syn.sdisjuncts = [] then
      let evs_eqs = List.fold_left (fun vs (a1, a2) -> vs_union vs (get_evs a1 a2)) vs_empty syn.seqs in
      let evs_neqs = List.fold_left (fun vs (a1, a2) -> vs_union vs (get_evs a1 a2)) vs_empty syn.sneqs in
      vs_union evs_eqs evs_neqs
    else begin
      List.fold_left (fun vs (s1, s2) -> 
        vs_union (vs_union (find_ev_eq_neq s1 vset) (find_ev_eq_neq s2 vset)) vs
      ) vs_empty syn.sdisjuncts   
    end
  in
  (* iterates until the set of existentials becomes saturated *)
  let rec saturate_ev syn evars =
    let new_evars = find_ev_eq_neq syn evars in
    if (vs_is_empty (vs_diff new_evars evars)) then new_evars
    else saturate_ev syn new_evars
  in
  let rec saturate_ev_cnt syn evars cnt =
    if cnt = 0 then evars
    else saturate_ev_cnt syn (find_ev_eq_neq syn evars) (cnt-1)
  in  
  (*let ev_sp = saturate_ev_cnt syn_form (find_ev_sp syn_form) 2 in*)
  let ev_sp = saturate_ev syn_form (find_ev_sp syn_form) in
  let rec elim_evars syn =
    (* ignore terms with heads from forbidden_heads *)
    let forbidden_heads = ["Ast"] in
    let rec is_not_forbidden arg =
      match arg with
      | Arg_var v -> true
      | Arg_string s -> true
      | Arg_op (name, args) -> 
        ((List.mem name forbidden_heads) <> true) && 
        (List.for_all (fun arg -> is_not_forbidden arg) args)
      | _ -> assert false
    in
    (* condition for killing a term *)
    let can_kill vs =
      (vs_is_empty vs <> true) &&  (* the set of free variables must be non empty *)
      (vs_is_empty (vs_inter ev_sp vs)) &&  (* the intersection with existentials in spatials must be empty *)
      (vs_for_all (fun v -> match v with Vars.EVar _ -> true | _ -> false) vs) (* in there should be only existential vars *)
    in
    (* filters terms in a multiset *)
    let rec filter_args_mset ms : SMSet.multiset =
      if SMSet.has_more ms then begin
        if can_kill (fv_args_list (snd (SMSet.peek ms)) vs_empty) &&
          ((List.mem (fst (SMSet.peek ms)) forbidden_heads) <> true) then
          filter_args_mset (snd (SMSet.remove ms))
        else
          filter_args_mset (SMSet.next ms)
      end
      else SMSet.restart ms
    in
    (* filters terms in a list of pairs *)
    let filter_args_pls xs =
      List.filter (fun (a1, a2) ->
        (can_kill (vs_union (fv_args a1 vs_empty) (fv_args a2 vs_empty)) <> true) &&
        (is_not_forbidden a1) && (is_not_forbidden a2)
      ) xs
    in
    if syn.sdisjuncts = [] then
      let plain = filter_args_mset syn.splain in
      let eqs = filter_args_pls syn.seqs in
      let neqs = filter_args_pls syn.sneqs in
      { sspat = syn.sspat;
        splain = plain;
        sdisjuncts = syn.sdisjuncts;
        seqs = eqs;
        sneqs = neqs }
    else
      let disjuncts = 
        List.map (fun (s1, s2) -> (elim_evars s1, elim_evars s2)) syn.sdisjuncts
      in
      { sspat = syn.sspat;
        splain = syn.splain;
        sdisjuncts = disjuncts;
        seqs = syn.seqs;
        sneqs = syn.sneqs }
  in
  elim_evars syn_form


let abs ts_form = 
  let syn = make_syntactic ts_form in
  let abs_syn = eliminate_existentials syn in (* perform syntactic abstraction *)
  let form, ts = convert_sf false (new_ts()) abs_syn in 
  mk_ts_form ts form


let match_and_remove
      remove (* should match terms be removed - true removes them, false leaves them *)
      ts
      term (*formula to match in *)
      pattern (*pattern to match *)
      cont
    =
  let rec mar_inner
	ts
	(term : RMSet.multiset)
	(cn (*current name*),cp (*current tuple pattern*))
	pattern(*remaining pattern*)
	count (*number of successive failures to match *)
	(cont : term_structure * RMSet.multiset -> 'a) : 'a =
      if RMSet.has_more term then
	(* actually do something *)
	let s,nterm = RMSet.remove term in
	if fst(s) = cn then
	  (* potential match *)
	  try
	    unifies ts cp (snd(s))
	      (fun ts ->
               (* If we are removing matched elements use nterm, otherwise revert to term *)
		let nterm = if remove then nterm else term in
		if SMSet.has_more pattern then
		  (* match next entry in the pattern*)
		  let ((nn,np), pattern) = SMSet.remove pattern in
		  (* If we are matching the same type of predicate still,
		     then must back the iterator up across the failed matches.  *)
		  let nterm = if nn=cn then (RMSet.back nterm count) else nterm in
		  let np,ts = make_tuple_pattern np ts in
		  mar_inner
		    ts
		    nterm
		    (nn, np)
		    pattern
		    0
		    cont
		else
                  (* No pattern left, done *)
		  cont (ts,RMSet.restart nterm)
	      )
	  with Backtrack.No_match ->
	    (* Failed to match *)
	    mar_inner ts (RMSet.next term) (cn,cp) pattern (count+1) cont
	else if fst(s) < cn then
	  (* keeping searching for a new predicate, as current is too low. *)
	  mar_inner ts (RMSet.next term) (cn,cp) pattern 0 cont
	else
	  (* We have missed it, so no match *)
	  raise No_match
      else
	(* pattern left, but nothing to match against *)
	raise No_match
  in
    (* Check the pattern is non-empty *)
    if SMSet.has_more pattern then
      let (cn,cp),pattern = SMSet.remove pattern in
      let cp,ts = make_tuple_pattern cp ts in
      mar_inner ts term (cn,cp) pattern 0 cont
    else
      (* Empty pattern just call continuation *)
      cont (ts,term)



(* Assume that assumption does not contain eqs or neqs, they are represented in ts *)
type sequent =
   {
    matched : RMSet.multiset;
    ts : term_structure;
    assumption : formula;
    obligation : formula;
  }

let pp_sequent ppf
  {matched=matched; ts=ts; assumption=assumption; obligation=obligation} =
    let pp_term = pp_c ts in 
    let rmf = pp_star.separator (pp_rmset_element "" pp_term) ppf in
    ignore (RMSet.fold rmf true matched);
    fprintf ppf "@ | ";
    let first = pp_ts' pp_star ppf true ts in
    ignore (pp_formula' pp_term pp_star ppf first assumption);
    fprintf ppf "@ |- ";
    pp_formula pp_term ppf obligation


let rec plain f =
  f.spat = RMSet.empty
    &&
  List.for_all (fun (x,y) -> plain x && plain y) f.disjuncts

let true_sequent (seq : sequent) : bool =
  (is_true seq.obligation)
    &&
  plain seq.assumption

let frame_sequent (seq : sequent) : bool =
  (seq.obligation = empty)

(* Stolen from Prover just for refactor *)
type sequent_rule = psequent * (psequent list list) * string * ((* without *) pform * pform) * (where list)


type pat_sequent =
    {
    assumption_same : syntactic_form;
    assumption_diff : syntactic_form;
    obligation_diff : syntactic_form;
  }

let convert_sequent (ps : psequent) : pat_sequent =
(*  fprintf !(Debug.proof_dump) "Converting sequent: %a@\n" string_pseq ps;*)
  let ps = match ps with
    pm,pa,po ->
      {
       assumption_same = convert_to_inner pm;
       assumption_diff = convert_to_inner pa;
       obligation_diff = convert_to_inner po;
     } in
(*  fprintf !(Debug.proof_dump) "Produced sequent: %a@ |@ %a@ |-@ %a@\n@\n" pp_sform ps.assumption_same pp_sform ps.assumption_diff pp_sform ps.obligation_diff; *)
  ps

type inner_sequent_rule =
    {
      conclusion : pat_sequent ;
      premises : pat_sequent list list;
      name : string;
      without_left : syntactic_form;
      without_right : syntactic_form;
      where : where list;
   }


let convert_rule (sr : sequent_rule) : inner_sequent_rule =
  match sr with
    conc,prems,name,(withoutl,withoutr),where ->
      {
       conclusion = convert_sequent conc;
       premises = List.map (List.map convert_sequent) prems;
       name = name;
       without_left = convert_to_inner withoutl;
       without_right = convert_to_inner withoutr;
       where = where;
     }


(* Match in syntactic ones too *)
let rec match_foo op ts form seqs cont =
  match seqs with
    [] -> cont (ts,form)
  | (x,y)::seqs ->
      let x,ts = add_pattern x ts in
      let y,ts = add_pattern y ts in
      try
	op ts x y (fun ts -> match_foo op ts form seqs cont)
      with No_match ->
	let rec f ts frms frms2=
	  match frms with
	    (a,b)::frms ->
	      begin
		try
		  unifies ts x a
		    (fun ts -> unifies ts y b
			(fun ts -> match_foo op ts (frms@frms2) seqs cont) )
		with No_match -> try
		  unifies ts x b
		    (fun ts -> unifies ts y a
			(fun ts -> match_foo op ts (frms@frms2) seqs cont) )
		with No_match ->
		  f ts frms ((a,b)::frms2)
	      end
	  | [] -> raise No_match
	in
	f ts form []


let match_eqs ts eqs seqs cont =
  match_foo unify_patterns ts eqs seqs cont

let match_neqs ts neqs sneqs cont =
  match_foo unify_not_equal_pattern ts neqs sneqs cont



let rec match_form remove ts form pat (cont : term_structure * formula -> 'a) : 'a =
  match_and_remove remove ts form.spat pat.sspat
    (fun (ts,nspat) ->
      match_and_remove remove ts form.plain pat.splain
	(fun (ts,nplain) ->
	  match_eqs ts form.eqs pat.seqs
	    (fun (ts,eqs) ->
	      match_neqs ts form.neqs pat.sneqs
		(fun (ts,neqs) ->
		  match_disjunct remove ts {form with
			      spat = nspat;
			      plain = nplain;
			      eqs = eqs;
			      neqs = neqs;
			    }
		    pat.sdisjuncts cont
		)
	    )
	)
    )
and match_disjunct remove ts form pat_disj cont =
  match pat_disj with
    [] -> cont (ts,form)
  | (x,y)::pat_disj ->
      try
	match_form remove ts form x (fun (ts,form) -> match_disjunct remove ts form pat_disj cont)
      with No_match ->
	match_form remove ts form y (fun (ts,form) -> match_disjunct remove ts form pat_disj cont)




(* Takes a formula, and returns a pair of formula with one of the
   original disjuncts eliminated.*)
let split_disjunct form =
  match form.disjuncts with
    [] -> raise No_match
  | (x,y)::disjuncts ->
      conjunction x {form with disjuncts = disjuncts},
      conjunction y {form with disjuncts = disjuncts}

let apply_or_left seq : sequent list =
  let a1,a2 = split_disjunct seq.assumption in
  [{seq with assumption = a1};
   {seq with assumption = a2}]

let apply_or_right seq : sequent list list =
  let o1,o2 = split_disjunct seq.obligation in
  [[{seq with obligation = o1}];
   [{seq with obligation = o2}]]


let get_frame seq =
  (*assert (frame_sequent seq);*) (* TODO: assertion broken by SMT, pick another *)
  mk_ts_form seq.ts seq.assumption

let rec get_frames seqs frms =
  match seqs with
  | [] -> frms
  | seq::seqs ->  get_frames seqs ((get_frame seq)::frms)

let get_frames seqs =
  get_frames seqs []


let convert_with_eqs fresh pform =
  let sf = convert_to_inner pform in
  let ts = new_ts () in
  let ts,form = convert_sf fresh ts sf in
  mk_ts_form form ts

let convert fresh ts pform =
  convert_sf_without_eqs fresh  ts (convert_to_inner pform)

let make_implies (heap : ts_formula) (pheap : pform) : sequent =
  let ts,form = break_ts_form heap in
  let rh,ts = convert false ts pheap in
  {ts = ts;
     assumption = form;
     obligation = rh;
     matched = RMSet.empty}


let make_implies_inner ts_form1 ts_form2 =
  let ts,form = break_ts_form ts_form1 in
  let sform =
    match !(ts_form2.cache_sform) with
      Some sform -> sform
    | None -> make_syntactic ts_form2 in
  ts_form2.cache_sform := Some sform;
  let rform,ts =  convert_sf_without_eqs false ts sform in
  {ts = ts;
    assumption = form;
    obligation = rform;
    matched = RMSet.empty}  
   

