
open Common;;

(*
 * The purpose of this module is just to decouple the AST from the
 * various passes that are interested in visiting "parts" of it.
 * If the AST shifts, we have better odds of the shift only affecting
 * this module rather than all of its clients. Similarly if the
 * clients only need to visit part, they only have to define the
 * part of the walk they're interested in, making it cheaper to define
 * multiple passes.
 *)

type visitor =
    {
      visit_stmt_pre: Ast.stmt -> unit;
      visit_stmt_post: Ast.stmt -> unit;
      visit_slot_identified_pre: (Ast.slot identified) -> unit;
      visit_slot_identified_post: (Ast.slot identified) -> unit;
      visit_expr_pre: Ast.expr -> unit;
      visit_expr_post: Ast.expr -> unit;
      visit_ty_pre: Ast.ty -> unit;
      visit_ty_post: Ast.ty -> unit;
      visit_constr_pre: Ast.constr -> unit;
      visit_constr_post: Ast.constr -> unit;
      visit_block_pre: Ast.block -> unit;
      visit_block_post: Ast.block -> unit;

      visit_lit_pre: Ast.lit -> unit;
      visit_lit_post: Ast.lit -> unit;
      visit_lval_pre: Ast.lval -> unit;
      visit_lval_post: Ast.lval -> unit;
      visit_mod_item_pre:
        Ast.ident -> ((Ast.ty_param identified) array) -> Ast.mod_item -> unit;
      visit_mod_item_post:
        Ast.ident -> ((Ast.ty_param identified) array) -> Ast.mod_item -> unit;
      visit_mod_type_item_pre:
        Ast.ident -> (Ast.ty_param array) -> Ast.mod_type_item -> unit;
      visit_mod_type_item_post:
        Ast.ident -> (Ast.ty_param array) -> Ast.mod_type_item -> unit;
      visit_crate_pre: Ast.crate -> unit;
      visit_crate_post: Ast.crate -> unit;
    }
;;


let empty_visitor =
  { visit_stmt_pre = (fun _ -> ());
    visit_stmt_post = (fun _ -> ());
    visit_slot_identified_pre = (fun _ -> ());
    visit_slot_identified_post = (fun _ -> ());
    visit_expr_pre = (fun _ -> ());
    visit_expr_post = (fun _ -> ());
    visit_ty_pre = (fun _ -> ());
    visit_ty_post = (fun _ -> ());
    visit_constr_pre = (fun _ -> ());
    visit_constr_post = (fun _ -> ());
    visit_block_pre = (fun _ -> ());
    visit_block_post = (fun _ -> ());
    visit_lit_pre = (fun _ -> ());
    visit_lit_post = (fun _ -> ());
    visit_lval_pre = (fun _ -> ());
    visit_lval_post = (fun _ -> ());
    visit_mod_item_pre = (fun _ _ _ -> ());
    visit_mod_item_post = (fun _ _ _ -> ());
    visit_mod_type_item_pre = (fun _ _ _ -> ());
    visit_mod_type_item_post = (fun _ _ _ -> ());
    visit_crate_pre = (fun _ -> ());
    visit_crate_post = (fun _ -> ()); }
;;

let path_managing_visitor
    (path:Ast.name_component Stack.t)
    (inner:visitor)
    : visitor =
  let visit_mod_item_pre ident params item =
    Stack.push (Ast.COMP_ident ident) path;
    inner.visit_mod_item_pre ident params item
  in
  let visit_mod_item_post ident params item =
    inner.visit_mod_item_post ident params item;
    ignore (Stack.pop path)
  in
    { inner with
        visit_mod_item_pre = visit_mod_item_pre;
        visit_mod_item_post = visit_mod_item_post;
    }
;;

let rec name_of ncs =
  match ncs with
      [] -> failwith "empty path"
    | [(Ast.COMP_ident i)] -> Ast.NAME_base (Ast.BASE_ident i)
    | [(Ast.COMP_app x)] -> Ast.NAME_base (Ast.BASE_app x)
    | [(Ast.COMP_idx _)] -> failwith "path-name contains COMP_idx"
    | nc::ncs -> Ast.NAME_ext (name_of ncs, nc)
;;

let path_to_name
    (path:Ast.name_component Stack.t)
    : Ast.name =
  name_of (stk_elts_from_top path)
;;


let mod_item_logging_visitor
    (logfn:string->unit)
    (path:Ast.name_component Stack.t)
    (inner:visitor)
    : visitor =
  let path_name _ = Ast.fmt_to_str Ast.fmt_name (path_to_name path) in
  let visit_mod_item_pre name params item =
    logfn (Printf.sprintf "entering %s" (path_name()));
    inner.visit_mod_item_pre name params item
  in
  let visit_mod_item_post name params item =
    logfn (Printf.sprintf "leaving %s" (path_name()));
    inner.visit_mod_item_post name params item;
  in
    { inner with
        visit_mod_item_pre = visit_mod_item_pre;
        visit_mod_item_post = visit_mod_item_post; }
;;


let walk_bracketed
    (pre:'a -> unit)
    (children:unit -> unit)
    (post:'a -> unit)
    (x:'a)
    : unit =
  begin
    pre x;
    children ();
    post x
  end
;;


let walk_option
    (walker:'a -> unit)
    (opt:'a option)
    : unit =
  match opt with
      None -> ()
    | Some v -> walker v
;;


let rec walk_crate
    (v:visitor)
    (crate:Ast.crate)
    : unit =
    walk_bracketed
      v.visit_crate_pre
      (fun _ -> walk_mod_items v crate.node.Ast.crate_items)
      v.visit_crate_post
      crate

and walk_mod_items
    (v:visitor)
    (items:Ast.mod_items)
    : unit =
  Hashtbl.iter (walk_mod_item v) items


and walk_mod_item
    (v:visitor)
    (name:Ast.ident)
    (item:Ast.mod_item)
    : unit =
  let children _ =
    match item.node.Ast.decl_item with
        Ast.MOD_ITEM_opaque_type ty
      | Ast.MOD_ITEM_public_type ty -> walk_ty v ty
      | Ast.MOD_ITEM_fn f -> walk_fn v f
      | Ast.MOD_ITEM_pred p -> walk_pred v p
      | Ast.MOD_ITEM_tag (htup, ttag, _) ->
          walk_header_tup v htup;
          walk_ty_tag v ttag

      | Ast.MOD_ITEM_mod (hdr, items) ->
          walk_option (fun (h,constrs) ->
                         walk_header_slots v h;
                         walk_constrs v constrs) hdr;
          walk_mod_items v items

  in
    walk_bracketed
      (v.visit_mod_item_pre name item.node.Ast.decl_params)
      children
      (v.visit_mod_item_post name item.node.Ast.decl_params)
      item


and walk_ty_tup v ttup = Array.iter (walk_slot v) ttup

and walk_ty_tag v ttag = Hashtbl.iter (fun _ t -> walk_ty_tup v t) ttag

and walk_ty
    (v:visitor)
    (ty:Ast.ty)
    : unit =
  let children _ =
    match ty with
        Ast.TY_tup ttup -> walk_ty_tup v ttup
      | Ast.TY_vec s -> walk_slot v s
      | Ast.TY_rec trec -> Array.iter (fun (_, s) -> walk_slot v s) trec
      | Ast.TY_tag ttag -> walk_ty_tag v ttag
      | Ast.TY_iso tiso -> Array.iter (walk_ty_tag v) tiso.Ast.iso_group
      | Ast.TY_fn tfn -> walk_ty_fn v tfn
      | Ast.TY_pred (slots, constrs) ->
          begin
            Array.iter (walk_slot v) slots;
            walk_constrs v constrs
          end
      | Ast.TY_chan t -> walk_ty v t
      | Ast.TY_port t -> walk_ty v t
      | Ast.TY_mod mt -> walk_mod_type_items v mt
      | Ast.TY_constrained (t,cs) ->
          begin
            walk_ty v t;
            walk_constrs v cs
          end
      | Ast.TY_named _ -> ()
      | Ast.TY_opaque _ -> ()
      | Ast.TY_param _ -> ()
      | Ast.TY_idx _ -> ()
      | Ast.TY_mach _ -> ()
      | Ast.TY_type -> ()
      | Ast.TY_str -> ()
      | Ast.TY_char -> ()
      | Ast.TY_int -> ()
      | Ast.TY_bool -> ()
      | Ast.TY_nil -> ()
      | Ast.TY_proc -> ()
      | Ast.TY_any -> ()
  in
    walk_bracketed
      v.visit_ty_pre
      children
      v.visit_ty_post
      ty


and walk_ty_sig
    (v:visitor)
    (s:Ast.ty_sig)
    : unit =
  begin
    Array.iter (walk_slot v) s.Ast.sig_input_slots;
    walk_constrs v s.Ast.sig_input_constrs;
    walk_slot v s.Ast.sig_output_slot;
  end


and walk_ty_fn
    (v:visitor)
    (tfn:Ast.ty_fn)
    : unit =
  let (tsig, _) = tfn in
  walk_ty_sig v tsig


and walk_mod_type_item
    (v:visitor)
    (name:Ast.ident)
    (item:Ast.mod_type_item)
    : unit =
  let children _ =
    match item.Ast.decl_item with
        Ast.MOD_TYPE_ITEM_opaque_type _ -> ()
      | Ast.MOD_TYPE_ITEM_public_type ty -> walk_ty v ty
      | Ast.MOD_TYPE_ITEM_pred p -> walk_ty_pred v p
      | Ast.MOD_TYPE_ITEM_mod m -> walk_mod_type_items v m
      | Ast.MOD_TYPE_ITEM_fn f -> walk_ty_fn v f
  in
    walk_bracketed
      (v.visit_mod_type_item_pre name item.Ast.decl_params)
      children
      (v.visit_mod_type_item_post name item.Ast.decl_params)
      item

and walk_ty_pred
    (v:visitor)
    (tpred:Ast.ty_pred)
    : unit =
  let (slots, constrs) = tpred in
    Array.iter (walk_slot v) slots;
    walk_constrs v constrs

and walk_mod_type_items
    (v:visitor)
    (tmod:Ast.ty_mod)
    : unit =
  let (hdr, items) = tmod in
    begin
      match hdr with
          None -> ()
        | Some (slots, constrs) ->
            Array.iter (walk_slot v) slots;
            walk_constrs v constrs
    end;
    Hashtbl.iter (walk_mod_type_item v) items


and walk_constrs
    (v:visitor)
    (cs:Ast.constrs)
    : unit =
  Array.iter (walk_constr v) cs

and walk_check_calls
    (v:visitor)
    (calls:Ast.check_calls)
    : unit =
  Array.iter
    begin
      fun (f, args) ->
        walk_lval v f;
        Array.iter (walk_atom v) args
    end
    calls


and walk_constr
    (v:visitor)
    (c:Ast.constr)
    : unit =
  walk_bracketed
    v.visit_constr_pre
    (fun _ -> ())
    v.visit_constr_post
    c

and walk_header_slots
    (v:visitor)
    (hslots:Ast.header_slots)
    : unit =
  Array.iter (fun (s,_) -> walk_slot_identified v s) hslots

and walk_header_tup
    (v:visitor)
    (htup:Ast.header_tup)
    : unit =
  Array.iter (walk_slot_identified v) htup

and walk_pred
    (v:visitor)
    (p:Ast.pred)
    : unit =
  walk_header_slots v p.Ast.pred_input_slots;
  walk_constrs v p.Ast.pred_input_constrs;
  walk_block v p.Ast.pred_body


and walk_fn
    (v:visitor)
    (f:Ast.fn)
    : unit =
  walk_header_slots v f.Ast.fn_input_slots;
  walk_constrs v f.Ast.fn_input_constrs;
  walk_slot_identified v f.Ast.fn_output_slot;
  walk_block v f.Ast.fn_body

and walk_slot_identified
    (v:visitor)
    (s:Ast.slot identified)
    : unit =
  walk_bracketed
    v.visit_slot_identified_pre
    (fun _ -> walk_slot v s.node)
    v.visit_slot_identified_post
    s


and walk_slot
    (v:visitor)
    (s:Ast.slot)
    : unit =
  walk_option (walk_ty v) s.Ast.slot_ty


and walk_stmt
    (v:visitor)
    (s:Ast.stmt)
    : unit =
  let walk_stmt_for
      (s:Ast.stmt_for)
      : unit =
    let (si,_) = s.Ast.for_slot in
    let (ss,lv) = s.Ast.for_seq in
      walk_slot_identified v si;
      Array.iter (walk_stmt v) ss;
      walk_lval v lv;
      walk_block v s.Ast.for_body
  in
  let walk_stmt_while
      (s:Ast.stmt_while)
      : unit =
    let (ss,e) = s.Ast.while_lval in
      Array.iter (walk_stmt v) ss;
      walk_expr v e;
      walk_block v s.Ast.while_body
  in
  let children _ =
    match s.node with
        Ast.STMT_log a ->
          walk_atom v a

      | Ast.STMT_init_rec (lv, atab, (*base*)_) ->
          walk_lval v lv;
          Array.iter (fun (_, _, a) -> walk_atom v a) atab

      | Ast.STMT_init_vec (lv, _, atoms) ->
          walk_lval v lv;
          Array.iter (walk_atom v) atoms

      | Ast.STMT_init_tup (lv, mut_atoms) ->
          walk_lval v lv;
          Array.iter (fun (_, a) -> walk_atom v a) mut_atoms

      | Ast.STMT_init_str (lv, _) ->
          walk_lval v lv

      | Ast.STMT_init_port lv ->
          walk_lval v lv

      | Ast.STMT_init_chan (chan,port) ->
          walk_option (walk_lval v) port;
          walk_lval v chan;

      | Ast.STMT_for f ->
          walk_stmt_for f

      | Ast.STMT_while w ->
          walk_stmt_while w

      | Ast.STMT_do_while w ->
          walk_stmt_while w

      | Ast.STMT_if i ->
          begin
            walk_expr v i.Ast.if_test;
            walk_block v i.Ast.if_then;
            walk_option (walk_block v) i.Ast.if_else
          end

      | Ast.STMT_block b ->
          walk_block v b

      | Ast.STMT_copy (lv,e,_) ->
          walk_lval v lv;
          walk_expr v e

      | Ast.STMT_call (dst,f,az) ->
          walk_lval v dst;
          walk_lval v f;
          Array.iter (walk_atom v) az

      | Ast.STMT_bind (dst, f, az) ->
          walk_lval v dst;
          walk_lval v f;
          Array.iter (walk_opt_atom v) az

      | Ast.STMT_spawn (dst,_,p,az) ->
          walk_lval v dst;
          walk_lval v p;
          Array.iter (walk_atom v) az

      | Ast.STMT_ret (_, ao) ->
          walk_option (walk_atom v) ao

      | Ast.STMT_put (_, at) ->
          walk_option (walk_atom v) at

      (* FIXME: this should have a param array, and invoke the visitors. *)
      | Ast.STMT_decl (Ast.DECL_mod_item (id, mi)) ->
          walk_mod_item v id mi

      | Ast.STMT_decl (Ast.DECL_slot (_, slot)) ->
          walk_slot_identified v slot

      | Ast.STMT_yield ->
          ()

      | Ast.STMT_join proc ->
          walk_lval v proc

      | Ast.STMT_send (dst,src) ->
          walk_lval v dst;
          walk_lval v src

      | Ast.STMT_recv (dst,src) ->
          walk_lval v dst;
          walk_lval v src

      | Ast.STMT_be (_, lv, ats) ->
          walk_lval v lv;
          Array.iter (walk_atom v) ats

      | Ast.STMT_check_expr e ->
          walk_expr v e

      | Ast.STMT_check (cs, calls) ->
          walk_constrs v cs;
          walk_check_calls v calls

      | Ast.STMT_check_if (cs,calls,b) ->
          walk_constrs v cs;
          walk_check_calls v calls;
          walk_block v b

      | Ast.STMT_prove cs ->
          walk_constrs v cs

      | Ast.STMT_alt_tag
          { Ast.alt_tag_lval = lval; Ast.alt_tag_arms = arms } ->
          walk_lval v lval;
          let walk_arm { node = (_, header_slots, block) } =
            walk_header_slots v header_slots;
            walk_block v block
          in
          Array.iter walk_arm arms

      (* FIXME (bug 541526): finish this as needed. *)
      | Ast.STMT_slice _
      | Ast.STMT_note _
      | Ast.STMT_foreach _
      | Ast.STMT_alt_type _
      | Ast.STMT_alt_port _ ->
          bug () "unimplemented statement type in Walk.walk_stmt"
  in
    walk_bracketed
      v.visit_stmt_pre
      children
      v.visit_stmt_post
      s


and walk_expr
    (v:visitor)
    (e:Ast.expr)
    : unit =
  let children _ =
    match e with
        Ast.EXPR_binary (_,aa,ab) ->
          walk_atom v aa;
          walk_atom v ab
      | Ast.EXPR_unary (_,a) ->
          walk_atom v a
      | Ast.EXPR_atom a ->
          walk_atom v a
  in
  walk_bracketed
    v.visit_expr_pre
    children
    v.visit_expr_post
    e

and walk_atom
    (v:visitor)
    (a:Ast.atom)
    : unit =
  match a with
      Ast.ATOM_literal ls -> walk_lit v ls.node
    | Ast.ATOM_lval lv -> walk_lval v lv


and walk_opt_atom
    (v:visitor)
    (ao:Ast.atom option)
    : unit =
  match ao with
      None -> ()
    | Some a -> walk_atom v a


and walk_lit
    (v:visitor)
    (li:Ast.lit)
    : unit =
  walk_bracketed
    v.visit_lit_pre
    (fun _ -> ())
    v.visit_lit_post
    li


and walk_lval
    (v:visitor)
    (lv:Ast.lval)
    : unit =
  walk_bracketed
    v.visit_lval_pre
    (fun _ -> ())
    v.visit_lval_post
    lv


and walk_block
    (v:visitor)
    (b:Ast.block)
    : unit =
  walk_bracketed
    v.visit_block_pre
    (fun _ -> (Array.iter (walk_stmt v) b.node))
    v.visit_block_post
    b
;;

(*
 * Local Variables:
 * fill-column: 70;
 * indent-tabs-mode: nil
 * buffer-file-coding-system: utf-8-unix
 * compile-command: "make -k -C ../.. 2>&1 | sed -e 's/\\/x\\//x:\\//g'";
 * End:
 *)
