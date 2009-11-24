(******************************************************************
 JStar: Separation logic verification tool for Java.  
 Copyright (c) 2007-2008,
    Dino Distefano <ddino@dcs.qmul.ac.uk>
    Matthew Parkinson <Matthew.Parkinson@cl.cam.ac.uk>
 All rights reserved. 
*******************************************************************)


open Pterm
open Plogic
open Rlogic
open Global_types
open Jparsetree
open Cfg_core
open Prover
open Specification
open Vars
open Support_symex
open Spec_def
open Methdec_core
(* global variables *)

let curr_logic: Prover.logic ref = ref Prover.empty_logic
let curr_abs_rules: Prover.logic ref = ref Prover.empty_logic





(* ================  transition system ==================  *)

type id = int

let set_group,grouped = let x = ref false in (fun y -> x := y),(fun () -> !x )

let fresh_node = let node_counter = ref 0 in fun () ->  let x = !node_counter in node_counter := x+1; x

let fresh_file = let file_id = ref 0 in fun () -> let x = !file_id in file_id := x+1;  Sys.getcwd() ^  "/" ^ !file ^ ".proof_file_"^(string_of_int x)^".txt"


type node = {mutable content : string; id : id; mutable ntype : ntype; mutable url : string; mutable edges : edge list; cfg : stmt_core option}
and  edge = string * string * node * node * string option

let graphe = ref []


let mk_node c id nt url ed cfg =
 { content =c; 
   id =id; 
   ntype =nt; 
   url =url; 
   edges =ed; 
   cfg =cfg
 }

let node_get_content (n:node) : string = 
  n.content 

let node_get_idd (n:node) : id = 
  n.id 

let node_get_ntype (n:node) : ntype = 
  n.ntype 

let node_get_url (n:node) : string = 
  n.url 


module Idmap = 
  Map.Make(struct 
	     type t = int option 
	     let compare = compare
	   end)

let graphn = ref  Idmap.empty
let startnodes : node list ref = ref []

let make_start_node node = startnodes := node::!startnodes

let escape_for_dot_label s =
  Str.global_replace (Str.regexp "\\\\n") "\\l" (String.escaped s)

let pp_dotty_transition_system () =
  let foname = (!file) ^ ".execution_core.dot~" in
  let dotty_outf=open_out foname in
  if Config.symb_debug() then Printf.printf "\n Writing transition system file execution_core.dot  \n";
  Printf.fprintf dotty_outf "digraph main { \nnode [shape=box,  labeljust=l];\n\n";
  Idmap.iter 
    (fun cfg nodes ->
      ((
       if grouped () then match cfg with Some cfg -> Printf.fprintf dotty_outf "subgraph cluster_cfg%i {\n"  cfg | _ -> ());
      List.iter (fun {content=label;id=id;ntype=ty;url=url;cfg=cfg} ->
	let label=escape_for_dot_label label in
	let url = if url = "" then "" else ", URL=\"file://" ^ url ^"\"" in
	match ty with 
	| Plain -> ()
	| Good ->  ()
	| Error ->  ()
	| UnExplored -> ()
	| Abs ->  Printf.fprintf dotty_outf "\n state%i[label=\"%s\",labeljust=l, color=yellow, style=filled%s]\n" id label url)
	nodes;
      if grouped () then match cfg with Some _ -> Printf.fprintf dotty_outf "\n}\n" | _ -> ());
      List.iter (fun {content=label;id=id;ntype=ty;url=url;cfg=cfg} ->
	let label=escape_for_dot_label label in
	let url = if url = "" then "" else ", URL=\"file://" ^ url ^"\"" in
	match ty with 
	  Plain ->  Printf.fprintf dotty_outf "\n state%i[label=\"%s\",labeljust=l%s]\n" id label url
	| Good ->  Printf.fprintf dotty_outf "\n state%i[label=\"%s\",labeljust=l, color=green, style=filled%s]\n" id label url
	| Error ->  Printf.fprintf dotty_outf "\n state%i[label=\"%s\",labeljust=l, color=red, style=filled%s]\n" id label url
	| UnExplored ->  Printf.fprintf dotty_outf "\n state%i[label=\"%s\",labeljust=l, color=orange, style=filled%s]\n" id label url
	| Abs -> () )
	nodes;
    )
    !graphn;
  List.iter (fun (l,c,s,d, o) ->
    let l = escape_for_dot_label l in
    let c = escape_for_dot_label c in
    Printf.fprintf dotty_outf "\n state%i -> state%i [label=\"%s\", tooltip=\"%s\"%s]" s.id d.id l c
	    (match o with 
	      None -> ""
	    | Some f -> Printf.sprintf ", URL=\"file://%s\", fontcolor=blue" f))
    !graphe;
  Printf.fprintf dotty_outf "\n\n\n}";
  close_out dotty_outf;
  Sys.rename foname (!file ^ ".execution_core.dot")


let add_node (label : string) (ty : ntype) (cfg : stmt_core option) = 
  let id = fresh_node () in 
  let node = {content=label; id=id;ntype=ty;url=""; edges=[]; cfg = cfg} in 
  let cfgid = 
    match cfg with 
      None -> None 
    | Some cfg -> Some (cfg.sid) in 
  graphn := Idmap.add cfgid (node::(try Idmap.find cfgid !graphn with Not_found -> [])) !graphn;
  node

let add_error_node label = add_node label Error None
let add_abs_node label cfg = add_node label Abs (Some cfg)
let add_good_node label = add_node label Good None
let add_node_unexplored label cfg = add_node label UnExplored (Some cfg)
let add_node label cfg = add_node label UnExplored (Some cfg)

let explore_node src = if src.ntype = UnExplored then src.ntype <- Plain

let add_abs_heap_node (heap : Rlogic.ts_form) cfg= 
  (Format.fprintf (Format.str_formatter) "%a" string_ts_form heap);
  add_abs_node (Format.flush_str_formatter ()) cfg

let add_heap_node (heap : Rlogic.ts_form) cfg = 
  (Format.fprintf (Format.str_formatter) "%a" string_ts_form heap);
  add_node (Format.flush_str_formatter ()) cfg

let add_error_heap_node (heap : Rlogic.ts_form) = 
  (Format.fprintf (Format.str_formatter) "%a" string_ts_form heap);
  add_error_node (Format.flush_str_formatter ())

let x = ref 0


let add_edge src dest label = 
  let edge = (label, "", src, dest, None) in
  graphe := edge::!graphe;
  src.edges <- edge::src.edges;
  explore_node src;
  if !x = 5 then (x:=0; pp_dotty_transition_system ()) else x :=!x+1


let add_edge_with_proof src dest label = 
  let f = fresh_file() in
  let out = open_out f in
  Prover.pprint_proof out;
  close_out out;
  explore_node src;
  let edge = (label, "", src, dest, Some f) in 
  graphe := edge::!graphe;
  src.edges <- edge::src.edges;
  if !x = 5 then (x:=0; pp_dotty_transition_system ()) else x :=!x+1

(*let add_edge_with_string_proof src dest label proof = 
  let f = fresh_file() in
  let out = open_out f in
  output_string out proof;
  close_out out;
  graphe := (label, src, dest, Some f)::!graphe*)

let add_url_to_node src proof = 
  let f = fresh_file() in
  let out = open_out f in
  List.iter (output_string out) proof;
  close_out out;
  src.url <- f

let add_id_form h cfg =
    let id=add_heap_node h cfg in
    (h,id)

let add_id_formset sheaps cfg =  List.map (fun h -> add_id_form h cfg) sheaps

let add_id_formset_edge src label sheaps cfg =  
  let sheaps_id = add_id_formset sheaps cfg in
  List.iter (fun dest -> add_edge_with_proof src (snd dest) label) sheaps_id;
  sheaps_id

let add_id_abs_form cfg h =
    let id=add_abs_heap_node h cfg in
    (h,id)

let add_id_abs_formset sheaps cfg =  List.map (add_id_abs_form cfg) sheaps


(* ================   ==================  *)


(* ================  work list algorithm ==================  *)

(* this type has support for  creating a transition system 
   (formula, id)
   id is a unique identifier of the formula
 *)
type formset_entry = Rlogic.ts_form * node

(* eventually this should be a more efficient data structure than list*)
type formset = formset_entry list 


type formset_hashtbl = (int, formset) Hashtbl.t

(* table associating a cfg node to a set of heaps *)
let formset_table : formset_hashtbl = Hashtbl.create 10000


let formset_table_add key s = 
  Hashtbl.add formset_table key s

let formset_table_replace key s = 
  Hashtbl.replace formset_table key s

let formset_table_mem key  = 
  Hashtbl.mem formset_table key 

let formset_table_find key =
  try 
    Hashtbl.find formset_table key
  with Not_found -> 
    []  (* Default case return false, empty list of disjunctions *)


let remove_id_formset formset =
  fst (List.split formset)


let rec param_sub il num sub = 
  match il with 
    [] -> sub
  | i::il -> param_sub il (num+1) (add (Vars.concretep_str (parameter num)) (i) sub)



let param_sub il =
  let sub' = add ret_var (Arg_var(ret_var))  empty in 
  let this_var = concretep_str this_var_name in 
  let sub' = add this_var (Arg_var(this_var))  sub' in 
  param_sub il 0 sub'
  


let param_this_sub il n = 
  let sub = param_sub il in 
  let nthis_var = concretep_str Support_syntax.this_var_name in 
  add nthis_var (name2args n)  sub 
 
let id_clone h = (form_clone (fst h) false, snd h)



let call_jsr_static (sheap,id) spec il node = 
  let sub' = param_sub il in
  let sub''= (*freshening_subs*) sub' in
  let spec'= Specification.sub_spec sub'' spec  in 
  let res = (jsr !curr_logic sheap spec') in
    match res with 
      None ->   
	let idd = add_error_node "ERROR" in
	add_edge_with_proof id idd 	
	  (Format.fprintf 
	     (Format.str_formatter) "%a:@\n %a" 
	     Pprinter_core.pp_stmt_core node.skind
	     Prover.pprint_counter_example (); 
	   Format.flush_str_formatter ());
        System.warning();
	Format.printf "\n\nERROR: While executing node %d:\n   %a\n"  
	  (node.sid) 
	  Pprinter_core.pp_stmt_core node.skind;
	Prover.print_counter_example ();
	System.reset(); 
	[]
	(*assert false*)
(*	  "Preheap:\n    %s\n\nPrecondition:\n   %s\nCannot find splitting to apply spec. Giving up! \n\n" sheap_string (Plogic.string_form spec.pre); assert false *)
    | Some r -> fst r





exception Contained


let check_postcondition heaps sheap =
  let sheap_noid=fst sheap in  
  try 
    let heap,id = List.find (fun (heap,id) -> (check_implication_frame !curr_logic (form_clone sheap_noid false) heap)!=[]) heaps in
    if Config.symb_debug() then 
      Printf.printf "\n\nPost okay \n";
    (*	let idd = add_good_node ("EXIT: "^(Pprinter.name2str m.name)) in *)
    add_edge_with_proof (snd sheap) id "exit";
    (*	add_edge id idd "";*)
  with Not_found -> 
    System.warning();
    let _= Printf.printf "\n\nERROR: cannot prove post\n"  in
    Prover.print_counter_example ();
    System.reset();
    List.iter (fun heap -> 
		 let idd = add_error_heap_node (fst heap) in 
		 add_edge_with_proof (snd sheap) idd 
		   (Format.fprintf 
		      (Format.str_formatter) "ERROR EXIT: @\n %a" 
		      Prover.pprint_counter_example (); 
		    Format.flush_str_formatter ()))
      heaps
      (*print_formset "\n\n Failed Heap:\n" [sheap]    *)

      


let rec exec n sheap = 
  let sheap_noid=fst sheap in
  Rlogic.kill_all_exists_names sheap_noid;
(*  if Config.symb_debug() then 
    Format.printf "Output to %i with heap@\n   %a@\n" (node_get_id n) (string_ts_form (Rterm.rao_create ())) sheap_noid; *)
  execute_core_stmt n sheap 


and execs_one n sheaps = 
  let rec f ls = 
    match ls with 
    | [] -> []
    | [s] ->  List.flatten (List.map (exec s) sheaps)
    | s::ls' ->  List.flatten(List.map (fun h -> exec s (id_clone h)) sheaps) @ (f ls') 
  in
  let succs=n.succs in
  match succs with 
    [] -> 
      if Config.symb_debug() then Printf.printf "Exit node %i\n" (n.sid);
      sheaps
  |  _ -> f succs

and execute_core_stmt n (sheap : formset_entry) : formset_entry list =
  let sheap_noid=fst sheap in
  Rlogic.kill_all_exists_names sheap_noid;
  let stm=n in
  if Config.symb_debug() then 
    Format.printf "@\nExecuting statement:@ %a" Pprinter_core.pp_stmt_core stm.skind; 
  if Config.symb_debug() then 
    Format.printf "@\nwith heap:@\n    %a@\n@\n@."  string_ts_form  sheap_noid; 
  if (Prover.check_inconsistency !curr_logic (form_clone sheap_noid false)) then 
    (if Config.symb_debug() then Printf.printf "\n\nInconsistent heap. Skip it!\n";
     let idd = add_good_node "Inconsistent"  in add_edge_with_proof (snd sheap) idd "proof";
     [])
  else (
   if Config.symb_debug() 
   then begin
     Printf.printf "\nStarting execution of node %i \n" (n.sid);
     Format.printf "@\nExecuting statement:@ %a%!" Pprinter_core.pp_stmt_core stm.skind; 
     Format.printf "@\nwith heap:@\n    %a@\n@\n%!"  string_ts_form sheap_noid; 
    end;
    (match stm.skind with 
    | Label_stmt_core l -> 
	     (*  Update the labels formset, if sheap already implied then fine, otherwise or it in. *)
	(let id = n.sid in 
	try
	  if Config.symb_debug() 
	  then Format.printf "@\nPre-abstraction:@\n    %a@."  string_ts_form  sheap_noid; 
	  let sheap_pre_abs = form_clone sheap_noid true in 
	  let sheaps_abs = Prover.abs !curr_abs_rules sheap_pre_abs in 
	  let sheaps_abs = List.map (fun x -> form_clone x true) sheaps_abs in 
	  if Config.symb_debug() 
	  then Format.printf "@\nPost-abstractionc count:@\n    %d@."  (List.length sheaps_abs);
	  List.iter Rlogic.kill_all_exists_names sheaps_abs;
	  if Config.symb_debug() 
	  then List.iter (fun sheap -> Format.printf "@\nPost-abstraction:@\n    %a@."  string_ts_form sheap) sheaps_abs; 
	  
	  let formset = (formset_table_find id) in 
(*		if Config.symb_debug() then (
   Format.printf "Testing inclusion of :@    %a" 
		    (Debug.list_format "@\n" (string_ts_form (Rterm.rao_create ()))) sheaps_abs;
   print_formset "in " (remove_id_formset formset)
   ); *)
	  explore_node (snd sheap);
	  let sheaps_with_id = add_id_abs_formset sheaps_abs n in
	  List.iter 
	    (fun sheap2 ->  
	      add_edge_with_proof 
		(snd sheap) 
		(snd sheap2) 
		("Abstract@"^(Debug.toString Pprinter_core.pp_stmt_core stm.skind))
	    ) 
	    sheaps_with_id;
	  let sheaps_with_id = List.filter 
	      (fun (sheap2,id2) -> 
		(let s = ref [] in 
		if  
		  (List.for_all
		     (fun (form,id) -> 
		       if check_implication_frame !curr_logic (form_clone sheap2 false) form  != []then 
			 (add_edge_with_proof id2 id ("Contains@"^(Debug.toString Pprinter_core.pp_stmt_core stm.skind)); false) 
		       else (s := ("\n---------------------------------------------------------\n" ^ (string_of_proof ())) :: !s; true))
		     formset)
		then ( 
		  if !s != [] then (add_url_to_node id2 !s); true
		    ) else false
		    )
		  )
	      sheaps_with_id in
		(*	    List.iter (fun h ->
		   add_edge (snd sheap) (snd h) (Pprinter.statement2str stm.skind)) sheaps_with_id;*)
	  formset_table_replace id (sheaps_with_id @ formset);
	  execs_one n (List.map id_clone sheaps_with_id)
	with Contained -> 
	  if Config.symb_debug() then Printf.printf "Formula contained.\n"; [])
    | Goto_stmt_core _ -> execs_one n [sheap]
    | Nop_stmt_core  -> execs_one n [sheap]
    | Assignment_core (vl, spec, il) -> 
	( match vl with 
	| [] -> 
	    let hs=call_jsr_static sheap spec il n in
	    let hs=add_id_formset_edge (snd sheap) (Debug.toString Pprinter_core.pp_stmt_core n.skind) hs n in
	    execs_one n hs
	| [v] ->
	    let eliminate_ret_var h =
	      let h = update_var_to v (Arg_var ret_var) h in 
	      kill_var ret_var h;
	      h
	    in
	    let hs=call_jsr_static sheap spec il n in
	    let hs=List.map eliminate_ret_var hs in 
	    let hs=add_id_formset_edge (snd sheap) (Debug.toString Pprinter_core.pp_stmt_core n.skind)  hs n in
	    execs_one n hs
	| _ -> assert false (* TODO be done *)
	      )
    | Throw_stmt_core _ -> assert  false 
	  ))
      
(* implements a work-list fidex point algorithm *)
(* the queue qu is a list of pairs [(node, expression option)...] the expression
is used to deal with if statement. It is the expression of the if statement is the predecessor
of the node is a if_stmt otherwise is None. In the beginning is always None for each node *)
let compute_fixed_point (stmts : stmt_core list)  (spec : Spec_def.spec) (lo : logic) (abs_rules : logic) =

  (* remove methods that are declared abstraction *)
  curr_logic:= lo;
  curr_abs_rules:=abs_rules;
 
  stmts_to_cfg stmts;
  match stmts with 
    [] -> assert false
  | s::stmts -> 
      let id = add_good_node ("Start") in  
      make_start_node id;
      let post = execute_core_stmt s (Rlogic.convert (spec.pre), id) in 
      let id_exit = add_good_node ("Exit") in 
      List.iter 
	(fun post -> 
	  check_postcondition [(Rlogic.convert spec.post,id_exit)] post) post




