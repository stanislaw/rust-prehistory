(*
 * LLVM translator.
 *)

open Common;;
open Transutil;;

let log cx = Session.log "trans"
  cx.Semant.ctxt_sess.Session.sess_log_trans
  cx.Semant.ctxt_sess.Session.sess_log_out
;;

let trans_crate
    (sem_cx:Semant.ctxt)
    (llctx:Llvm.llcontext)
    (sess:Session.sess)
    (crate:Ast.crate)
    : Llvm.llmodule =

  let iflog thunk =
    if sess.Session.sess_log_trans
    then thunk ()
    else ()
  in

  (* Helpers for adding metadata. *)
  let (dbg_mdkind:int) = Llvm.mdkind_id llctx "dbg" in
  let set_dbg_metadata (inst:Llvm.llvalue) (md:Llvm.llvalue) : unit =
    Llvm.set_metadata inst dbg_mdkind md
  in
  let md_str (s:string) : Llvm.llvalue = Llvm.mdstring llctx s in
  let md_node (vals:Llvm.llvalue array) : Llvm.llvalue =
    Llvm.mdnode llctx vals
  in
  let const_i32 (i:int) : Llvm.llvalue =
    Llvm.const_int (Llvm.i32_type llctx) i
  in
  let const_i1 (i:int) : Llvm.llvalue =
    Llvm.const_int (Llvm.i1_type llctx) i
  in
  let llvm_debug_version : int = 0x8 lsl 16 in
  let const_dw_tag (tag:Dwarf.dw_tag) : Llvm.llvalue =
    const_i32 (llvm_debug_version lor (Dwarf.dw_tag_to_int tag))
  in

  (* Translation of our node_ids into LLVM identifiers, which are strings. *)
  let next_anon_llid = ref 0 in
  let num_llid num klass = Printf.sprintf "%s%d" klass num in
  let anon_llid klass =
    let llid = num_llid !next_anon_llid klass in
    next_anon_llid := !next_anon_llid + 1;
    llid
  in
  let node_llid (node_id_opt:node_id option) : (string -> string) =
    match node_id_opt with
        None -> anon_llid
      | Some (Node num) -> num_llid num
  in

  (*
   * Returns a bogus value for use in stub code that hasn't been implemented
   * yet.
   *
   * TODO: On some joyous day, remove me.
   *)
  let bogus = Llvm.const_null (Llvm.i32_type llctx) in
  let bogus_ptr = Llvm.const_null (Llvm.pointer_type (Llvm.i32_type llctx)) in

  let llnilty = Llvm.array_type (Llvm.i1_type llctx) 0 in
  let llnil = Llvm.const_array (Llvm.i1_type llctx) [| |] in

  let ty_of_item = Hashtbl.find sem_cx.Semant.ctxt_all_item_types in
  let ty_of_slot n = Semant.slot_ty (Semant.get_slot sem_cx n) in

  let filename = Session.filename_of sess.Session.sess_in in
  let llmod = Llvm.create_module llctx filename in

  let (abi:Llabi.abi) = Llabi.declare_abi llctx llmod in
  let (crate_ptr:Llvm.llvalue) =
    Llvm.declare_global abi.Llabi.crate_ty "rust_crate" llmod
  in

  let (void_ty:Llvm.lltype) = Llvm.void_type llctx in
  let (word_ty:Llvm.lltype) = abi.Llabi.word_ty in
  let (wordptr_ty:Llvm.lltype) = Llvm.pointer_type word_ty in
  let (task_ty:Llvm.lltype) = abi.Llabi.task_ty in
  let (task_ptr_ty:Llvm.lltype) = Llvm.pointer_type task_ty in
  let fn_ty (out:Llvm.lltype) (args:Llvm.lltype array) : Llvm.lltype =
    Llvm.function_type out args
  in

  let imm (i:int64) : Llvm.llvalue =
    Llvm.const_int word_ty (Int64.to_int i)
  in

  let asm_glue = Llasm.get_glue llctx llmod abi sess in

  let llty_str llty =
    Llvm.string_of_lltype llty
  in

  let llval_str llv =
    let ts = llty_str (Llvm.type_of llv) in
      match Llvm.value_name llv with
          "" ->
            Printf.sprintf "<anon=%s>" ts
        | s -> Printf.sprintf "<%s=%s>" s ts
  in

  let llvals_str llvals =
    (String.concat ", "
       (Array.to_list
          (Array.map llval_str llvals)))
  in

  let build_call callee args rvid builder =
    iflog
      begin
        fun _ ->
          let name = Llvm.value_name callee in
          log sem_cx "build_call: %s(%s)" name (llvals_str args);
          log sem_cx "build_call: typeof(%s) = %s"
            name (llty_str (Llvm.type_of callee))
      end;
    Llvm.build_call callee args rvid builder
  in

  (* Upcall translation *)

  let extern_upcalls = Hashtbl.create 0 in
  let trans_upcall
      (llbuilder:Llvm.llbuilder)
      (lltask:Llvm.llvalue)
      (name:string)
      (lldest:Llvm.llvalue option)
      (llargs:Llvm.llvalue array) =
    let n = Array.length llargs in
    let llglue = asm_glue.Llasm.asm_upcall_glues.(n) in
    let llupcall = htab_search_or_add extern_upcalls name
      begin
        fun _ ->
          let args_ty =
            Array.append
              [| task_ptr_ty |]
              (Array.init n (fun i -> Llvm.type_of llargs.(i)))
          in
          let out_ty = match lldest with
              None -> void_ty
            | Some v -> Llvm.type_of v
          in
          let fty = fn_ty out_ty args_ty in
            (* 
             * NB: At this point it actually doesn't matter what type
             * we gave the upcall function, as we're just going to
             * pointercast it to a word and pass it to the upcall-glue
             * for now. But possibly in the future it might matter if
             * we develop a proper upcall calling convention.
             *)
            Llvm.declare_function name fty llmod
      end
    in
      (* Cast everything to plain words so we can hand off to the glue. *)
    let llupcall = Llvm.const_pointercast llupcall word_ty in
    let llargs =
      Array.map
        (fun arg ->
           Llvm.build_pointercast arg word_ty
             (anon_llid "arg") llbuilder)
        llargs
    in
    let llallargs = Array.append [| lltask; llupcall |] llargs in
    let llid = anon_llid "rv" in
    let llrv = build_call llglue llallargs llid llbuilder in
      Llvm.set_instruction_call_conv Llvm.CallConv.c llrv;
      match lldest with
          None -> ()
        | Some lldest ->
            let lldest =
              Llvm.build_pointercast lldest wordptr_ty "" llbuilder
            in
              ignore (Llvm.build_store llrv lldest llbuilder);
  in

  let upcall
      (llbuilder:Llvm.llbuilder)
      (lltask:Llvm.llvalue)
      (name:string)
      (lldest:Llvm.llvalue option)
      (llargs:Llvm.llvalue array)
      : unit =
    trans_upcall llbuilder lltask name lldest llargs
  in

  let trans_free
      (llbuilder:Llvm.llbuilder)
      (lltask:Llvm.llvalue)
      (src:Llvm.llvalue)
      : unit =
    upcall llbuilder lltask "upcall_free" None [| src |]
  in

  (*
   * let trans_malloc (llbuilder:Llvm.llbuilder)
   *                  (dst:Llvm.llvalue) (nbytes:int64) : unit =
   *   upcall llbuilder "upcall_malloc" (Some dst) [| imm nbytes |]
   * in
   *)

  (* Type translation *)

  let lltys = Hashtbl.create 0 in

  let trans_mach_ty (mty:ty_mach) : Llvm.lltype =
    let tycon =
      match mty with
          TY_u8 | TY_i8 -> Llvm.i8_type
        | TY_u16 | TY_i16 -> Llvm.i16_type
        | TY_u32 | TY_i32 -> Llvm.i32_type
        | TY_u64 | TY_i64 -> Llvm.i64_type
        | TY_f32 -> Llvm.float_type
        | TY_f64 -> Llvm.double_type
    in
      tycon llctx
  in


  let rec trans_ty_full (ty:Ast.ty) : Llvm.lltype =
    let p t = Llvm.pointer_type t in
    let s ts = Llvm.struct_type llctx ts in
    let opaque _ = Llvm.opaque_type llctx in
    let vec_body_ty _ =
      s [| word_ty; word_ty; word_ty; (opaque()) |]
    in
    let rc_opaque_ty =
      s [| word_ty; (opaque()) |]
    in
    match ty with
        Ast.TY_any -> opaque ()
      | Ast.TY_nil -> llnilty
      | Ast.TY_bool -> Llvm.i1_type llctx
      | Ast.TY_mach mty -> trans_mach_ty mty
      | Ast.TY_int -> word_ty
      | Ast.TY_uint -> word_ty
      | Ast.TY_char -> Llvm.i32_type llctx
      | Ast.TY_vec _
      | Ast.TY_str -> p (vec_body_ty())

      | Ast.TY_fn tfn ->
          let (tsig, _) = tfn in
          let lloutptr = p (trans_slot None tsig.Ast.sig_output_slot) in
          let lltaskty = p abi.Llabi.task_ty in
          let llins = Array.map (trans_slot None) tsig.Ast.sig_input_slots in
            fn_ty void_ty (Array.append [| lloutptr; lltaskty |] llins)

      | Ast.TY_tup slots ->
          s (Array.map (trans_slot None) slots)

      | Ast.TY_rec entries ->
          s (Array.map (fun e -> trans_slot None (snd e)) entries)

      | Ast.TY_constrained (ty', _) -> trans_ty ty'

      | Ast.TY_chan _ | Ast.TY_port _ | Ast.TY_task  ->
          p rc_opaque_ty

      | Ast.TY_native _ ->
          word_ty

      | Ast.TY_tag _ | Ast.TY_iso _ | Ast.TY_idx _
      | Ast.TY_obj _ | Ast.TY_type -> (opaque()) (* TODO *)

      | Ast.TY_param _ | Ast.TY_named _ ->
          bug () "unresolved type in lltrans"

  and trans_ty t =
    htab_search_or_add lltys t (fun _ -> trans_ty_full t)

  (* Translates the type of a slot into the corresponding LLVM type. If the
   * id_opt parameter is specified, then the type will be fetched from the
   * context. *)
  and trans_slot (id_opt:node_id option) (slot:Ast.slot) : Llvm.lltype =
    let ty =
      match id_opt with
          Some id -> ty_of_slot id
        | None -> Semant.slot_ty slot
    in
    let base_llty = trans_ty ty in
      match slot.Ast.slot_mode with
          Ast.MODE_exterior _
        | Ast.MODE_alias _ ->
            Llvm.pointer_type base_llty
        | Ast.MODE_interior _ -> base_llty
  in

  let get_element_ptr
      (llbuilder:Llvm.llbuilder)
      (ptr:Llvm.llvalue)
      (i:int)
      : Llvm.llvalue =
    (* 
     * GEP takes a first-index of zero. Because it must! And this is
     * sufficiently surprising that the GEP FAQ exists. And you must
     * read it.
     *)
    let deref_ptr = Llvm.const_int (Llvm.i32_type llctx) 0 in
    let idx = Llvm.const_int (Llvm.i32_type llctx) i in
      Llvm.build_gep ptr [| deref_ptr; idx |] (anon_llid "gep") llbuilder
  in

  let free_ty
      (llbuilder:Llvm.llbuilder)
      (lltask:Llvm.llvalue)
      (ty:Ast.ty)
      (ptr:Llvm.llvalue)
      : unit =
    match ty with
        Ast.TY_port _
      | Ast.TY_chan _
      | Ast.TY_task -> bug () "unimplemented ty in Lltrans.free_ty"
      | _ -> trans_free llbuilder lltask ptr
  in

  let rec iter_ty_slots_full
      (llbuilder:Llvm.llbuilder ref)
      (ty:Ast.ty)
      (dst_ptr:Llvm.llvalue)
      (src_ptr:Llvm.llvalue)
      (f:(Llvm.llvalue
          -> Llvm.llvalue
            -> Ast.slot
              -> (Ast.ty_iso option)
                -> unit))
      (curr_iso:Ast.ty_iso option)
      : unit =

    (* NB: must deref llbuilder at call-time; don't curry this. *)
    let gep p i = get_element_ptr (!llbuilder) p i in

    match ty with
        Ast.TY_rec entries ->
          iter_rec_slots gep dst_ptr src_ptr entries f curr_iso

      | Ast.TY_tup slots ->
          iter_tup_slots gep dst_ptr src_ptr slots f curr_iso

      | Ast.TY_tag _
      | Ast.TY_iso _
      | Ast.TY_fn _
      | Ast.TY_obj _ ->
          bug () "unimplemented ty in Lltrans.iter_ty_slots_full"

      | _ -> ()

  and iter_ty_slots
      (llbuilder:Llvm.llbuilder ref)
      (ty:Ast.ty)
      (ptr:Llvm.llvalue)
      (f:Llvm.llvalue -> Ast.slot -> (Ast.ty_iso option) -> unit)
      (curr_iso:Ast.ty_iso option)
      : unit =
    iter_ty_slots_full llbuilder ty ptr ptr
      (fun _ src_ptr slot curr_iso -> f src_ptr slot curr_iso)
      curr_iso

  and drop_ty
      (llbuilder:Llvm.llbuilder ref)
      (lltask:Llvm.llvalue)
      (ty:Ast.ty)
      (ptr:Llvm.llvalue)
      (curr_iso:Ast.ty_iso option)
      : unit =
    iter_ty_slots llbuilder ty ptr (drop_slot llbuilder lltask) curr_iso

  and drop_slot
      (llbuilder:Llvm.llbuilder ref)
      (lltask:Llvm.llvalue)
      (slot_ptr:Llvm.llvalue)
      (slot:Ast.slot)
      (curr_iso:Ast.ty_iso option)
      : unit =

    let llfn = Llvm.block_parent (Llvm.insertion_block (!llbuilder)) in
    let llty = trans_slot None slot in
    let ty = Semant.slot_ty slot in

    let new_block klass =
      let llblock = Llvm.append_block llctx (anon_llid klass) llfn in
      let llbuilder = Llvm.builder_at_end llctx llblock in
        (llblock, llbuilder)
    in

    let if_ptr_in_slot_not_null
        (inner:Llvm.llvalue -> Llvm.llbuilder -> Llvm.llbuilder)
        (llbuilder:Llvm.llbuilder)
        : Llvm.llbuilder =
      let ptr = Llvm.build_load slot_ptr (anon_llid "tmp") llbuilder in
      let null = Llvm.const_pointer_null llty in
      let test =
        Llvm.build_icmp Llvm.Icmp.Ne null ptr (anon_llid "nullp") llbuilder
      in
      let (llthen, llthen_builder) = new_block "then" in
      let (llnext, llnext_builder) = new_block "next" in
        ignore (Llvm.build_cond_br test llthen llnext llbuilder);
        let llthen_builder = inner ptr llthen_builder in
          ignore (Llvm.build_br llnext llthen_builder);
          llnext_builder
    in

    let decr_refcnt_and_if_zero
        (rc_elt:int)
        (inner:Llvm.llvalue -> Llvm.llbuilder -> Llvm.llbuilder)
        (ptr:Llvm.llvalue)
        (llbuilder:Llvm.llbuilder)
        : Llvm.llbuilder  =
      let rc_ptr = get_element_ptr llbuilder ptr rc_elt in
      let rc = Llvm.build_load rc_ptr (anon_llid "rc") llbuilder in
      let rc = Llvm.build_sub rc (imm 1L) (anon_llid "tmp") llbuilder in
      let _ = Llvm.build_store rc rc_ptr llbuilder in
        log sem_cx "rc type: %s" (llval_str rc);
      let test =
        Llvm.build_icmp Llvm.Icmp.Eq
          rc (imm 0L) (anon_llid "zerop") llbuilder
      in
      let (llthen, llthen_builder) = new_block "then" in
      let (llnext, llnext_builder) = new_block "next" in
        ignore (Llvm.build_cond_br test llthen llnext llbuilder);
        let llthen_builder = inner ptr llthen_builder in
          ignore (Llvm.build_br llnext llthen_builder);
          llnext_builder
    in

    let free_and_null_out_slot
        (ptr:Llvm.llvalue)
        (llbuilder:Llvm.llbuilder)
        : Llvm.llbuilder =
      free_ty llbuilder lltask ty ptr;
      let null = Llvm.const_pointer_null llty in
        ignore (Llvm.build_store null slot_ptr llbuilder);
        llbuilder
    in

      begin
          match slot_mem_ctrl slot with
              MEM_rc_struct
            | MEM_gc ->
                llbuilder :=
                  if_ptr_in_slot_not_null
                    (decr_refcnt_and_if_zero
                       Abi.exterior_rc_slot_field_refcnt
                       free_and_null_out_slot)
                    (!llbuilder)

            | MEM_rc_opaque ->
                llbuilder :=
                  if_ptr_in_slot_not_null
                    (decr_refcnt_and_if_zero
                       Abi.exterior_rc_slot_field_refcnt
                       free_and_null_out_slot)
                    (!llbuilder)

            | MEM_interior when Semant.type_is_structured ty ->
                (* FIXME: to handle recursive types, need to call drop
                   glue here, not inline. *)
                drop_ty llbuilder lltask ty slot_ptr curr_iso

            | _ -> ()
        end
  in

  let (llitems:(node_id, Llvm.llvalue) Hashtbl.t) = Hashtbl.create 0 in
  let declare_mod_item
      (name:Ast.ident)
      { node = { Ast.decl_item = (item:Ast.mod_item') }; id = id }
      : unit =
    let full_name = Semant.item_str sem_cx id in
    let line_num =
      match Session.get_span sess id with
          None -> 0
        | Some span ->
            let (_, line, _) = span.lo in
              line
    in
      match item with
          Ast.MOD_ITEM_fn _ ->
            let llty = trans_ty (ty_of_item id) in
            let llfn = Llvm.declare_function ("_rust_" ^ name) llty llmod in
            let meta =
              md_node
                [|
                  const_dw_tag Dwarf.DW_TAG_subprogram;
                  const_i32 0; (* unused *)
                  const_i32 0; (* context metadata llvalue *)
                  md_str name;
                  md_str full_name;
                  md_str full_name;
                  const_i32 0; (* file metadata llvalue *)
                  const_i32 line_num;
                  const_i32 0; (* type descriptor metadata llvalue *)
                  const_i1 1;  (* flag: local to compile unit? *)
                  const_i1 1;  (* flag: defined in compile unit? *)
                |]
            in
              Llvm.set_function_call_conv Llvm.CallConv.c llfn;
              Hashtbl.add llitems id llfn;

              (* FIXME: Adding metadata does not work yet. . *)
              let _ = fun _ -> set_dbg_metadata llfn meta in
                ()

        | _ -> () (* TODO *)
  in

  let trans_fn
      ({
        Ast.fn_input_slots = (header_slots:Ast.header_slots);
        Ast.fn_body = (body:Ast.block)
      }:Ast.fn)
      (fn_id:node_id)
      : unit =
    let llfn = Hashtbl.find llitems fn_id in
    let lloutptr = Llvm.param llfn 0 in
    let lltask = Llvm.param llfn 1 in

    (* LLVM requires that functions be grouped into basic blocks terminated by
     * terminator instructions, while our AST is less strict. So we have to do
     * a little trickery here to wrangle the statement sequence into LLVM's
     * format. *)

    let new_block id_opt klass =
      let llblock = Llvm.append_block llctx (node_llid id_opt klass) llfn in
      let llbuilder = Llvm.builder_at_end llctx llblock in
      (llblock, llbuilder)
    in

    (* Build up the slot-to-llvalue mapping, allocating space along the
     * way. *)
    let slot_to_llvalue = Hashtbl.create 0 in
    let (_, llinitbuilder) = new_block None "init" in

    (* Allocate space for arguments (needed because arguments are lvalues in
     * Rust), and store them in the slot-to-llvalue mapping. *)
    let n_implicit_args = 2 in
    let build_arg idx llargval =
      if idx >= n_implicit_args
      then
        let ({ id = id }, ident) = header_slots.(idx - 2) in
        Llvm.set_value_name ident llargval;
        let llarg =
          let llty = Llvm.type_of llargval in
          Llvm.build_alloca llty (ident ^ "_ptr") llinitbuilder
        in
        ignore (Llvm.build_store llargval llarg llinitbuilder);
        Hashtbl.add slot_to_llvalue id llarg
    in
    Array.iteri build_arg (Llvm.params llfn);

    (* Allocate space for all the blocks' slots.
     * and zero the exteriors. *)
    let init_block (block_id:node_id) : unit =
      let init_slot
          (key:Ast.slot_key)
          (slot_id:node_id)
          (slot:Ast.slot)
          : unit =
        let name = Ast.sprintf_slot_key () key in
        let llty = trans_slot (Some slot_id) slot in
        let llptr = Llvm.build_alloca llty name llinitbuilder in
          begin
            match slot_mem_ctrl slot with
                MEM_rc_struct
              | MEM_rc_opaque
              | MEM_gc ->
                  ignore (Llvm.build_store
                            (Llvm.const_pointer_null llty)
                            llptr llinitbuilder);
              | _ -> ()
          end;
          Hashtbl.add slot_to_llvalue slot_id llptr
      in
        iter_block_slots sem_cx block_id init_slot
    in

    let exit_block
        (llbuilder:Llvm.llbuilder)
        (block_id:node_id)
        : Llvm.llbuilder =
      let r = ref llbuilder in
        iter_block_slots sem_cx block_id
          begin
            fun _ slot_id slot ->
              if (not (Semant.slot_is_obj_state sem_cx slot_id))
              then
                let ptr = Hashtbl.find slot_to_llvalue slot_id in
                  drop_slot r lltask ptr slot None
          end;
        !r
    in

    List.iter init_block (Hashtbl.find sem_cx.Semant.ctxt_frame_blocks fn_id);

    let static_str (s:string) : Llvm.llvalue =
      Llvm.define_global (anon_llid "str") (Llvm.const_stringz llctx s) llmod
    in


    (* Translates a list of AST statements to a sequence of LLVM instructions.
     * The supplied "terminate" function appends the appropriate terminator
     * instruction to the instruction stream. It may or may not be called,
     * depending on whether the AST contains a terminating instruction
     * explicitly. *)
    let rec trans_stmts
        (block_id:node_id)
        (llbuilder:Llvm.llbuilder)
        (stmts:Ast.stmt list)
        (terminate:(Llvm.llbuilder -> node_id -> unit))
        : unit =
      let trans_literal
          (lit:Ast.lit)
          : Llvm.llvalue =
        match lit with
            Ast.LIT_nil -> llnil
          | Ast.LIT_bool value ->
            Llvm.const_int (Llvm.i1_type llctx) (if value then 1 else 0)
          | Ast.LIT_mach (mty, value, _) ->
            let llty = trans_mach_ty mty in
            Llvm.const_of_int64 llty value (mach_is_signed mty)
          | Ast.LIT_int (value, _) ->
            Llvm.const_of_int64 (Llvm.i32_type llctx) value true
          | Ast.LIT_uint (value, _) ->
            Llvm.const_of_int64 (Llvm.i32_type llctx) value false
          | Ast.LIT_char ch ->
            Llvm.const_int (Llvm.i32_type llctx) ch
      in

      (* Translates an lval by reference into the appropriate pointer
       * value. *)
      let trans_lval (lval:Ast.lval) : Llvm.llvalue =
        iflog (fun _ -> log sem_cx "trans_lval: %a" Ast.sprintf_lval lval);
        match lval with
            Ast.LVAL_base { id = base_id } ->
              let id =
                Hashtbl.find sem_cx.Semant.ctxt_lval_to_referent base_id
              in
              let referent = Hashtbl.find sem_cx.Semant.ctxt_all_defns id in
              begin
                match referent with
                    Semant.DEFN_slot _ -> Hashtbl.find slot_to_llvalue id
                  | Semant.DEFN_item _ -> Hashtbl.find llitems id
                  | _ -> bogus_ptr (* TODO *)
              end
          | Ast.LVAL_ext _ -> bogus_ptr (* TODO *)
      in

      let trans_atom (atom:Ast.atom) : Llvm.llvalue =
        iflog (fun _ -> log sem_cx "trans_atom: %a" Ast.sprintf_atom atom);
        match atom with
            Ast.ATOM_literal { node = lit } -> trans_literal lit
          | Ast.ATOM_lval lval ->
              Llvm.build_load (trans_lval lval) (anon_llid "tmp") llbuilder
      in

      let trans_binary_expr
          ((op:Ast.binop), (lhs:Ast.atom), (rhs:Ast.atom))
          : Llvm.llvalue =
        (* Evaluate the operands in the proper order. *)
        let (lllhs, llrhs) =
          match op with
              Ast.BINOP_or | Ast.BINOP_and | Ast.BINOP_eq | Ast.BINOP_ne
                  | Ast.BINOP_lt | Ast.BINOP_le | Ast.BINOP_ge | Ast.BINOP_gt
                  | Ast.BINOP_lsl | Ast.BINOP_lsr | Ast.BINOP_asr
                  | Ast.BINOP_add | Ast.BINOP_sub | Ast.BINOP_mul
                  | Ast.BINOP_div | Ast.BINOP_mod | Ast.BINOP_xor ->
                (trans_atom lhs, trans_atom rhs)
            | Ast.BINOP_send ->
                let llrhs = trans_atom rhs in
                let lllhs = trans_atom lhs in
                (lllhs, llrhs)
        in
        let llid = anon_llid "expr" in
        match op with
            Ast.BINOP_eq ->
              (* TODO: equality works on more than just integers *)
              Llvm.build_icmp Llvm.Icmp.Eq lllhs llrhs llid llbuilder

            (* TODO: signed/unsigned distinction, floating point *)
          | Ast.BINOP_add -> Llvm.build_add lllhs llrhs llid llbuilder
          | Ast.BINOP_sub -> Llvm.build_sub lllhs llrhs llid llbuilder
          | Ast.BINOP_mul -> Llvm.build_mul lllhs llrhs llid llbuilder
          | Ast.BINOP_div -> Llvm.build_sdiv lllhs llrhs llid llbuilder
          | Ast.BINOP_mod -> Llvm.build_srem lllhs llrhs llid llbuilder

          | _ -> bogus (* TODO *)
      in

      let trans_unary_expr _ = bogus in (* TODO *)

      let trans_expr (expr:Ast.expr) : Llvm.llvalue =
        iflog (fun _ -> log sem_cx "trans_expr: %a" Ast.sprintf_expr expr);
        match expr with
            Ast.EXPR_binary binexp -> trans_binary_expr binexp
          | Ast.EXPR_unary unexp -> trans_unary_expr unexp
          | Ast.EXPR_atom atom -> trans_atom atom
      in

      let trans_log_str (atom:Ast.atom) : unit =
        upcall llbuilder lltask "upcall_log_str" None [| trans_atom atom |]
      in

      let trans_log_int (atom:Ast.atom) : unit =
        upcall llbuilder lltask "upcall_log_int" None [| trans_atom atom |]
      in

      let trans_fail
          (llbuilder:Llvm.llbuilder)
          (lltask:Llvm.llvalue)
          (reason:string)
          (stmt_id:node_id)
          : unit =
        let (file, line, _) =
          match Session.get_span sem_cx.Semant.ctxt_sess stmt_id with
              None -> ("<none>", 0, 0)
            | Some sp -> sp.lo
        in
        upcall llbuilder lltask "upcall_fail" None [|
          static_str reason;
          static_str file;
          Llvm.const_int (Llvm.i32_type llctx) line
        |];
        ignore (Llvm.build_unreachable llbuilder)
      in

      (* FIXME: this may be irrelevant; possibly LLVM will wind up
       * using GOT and such wherever it needs to to achieve PIC
       * data.
       *)
      (*
        let crate_rel (v:Llvm.llvalue) : Llvm.llvalue =
        let v_int = Llvm.const_pointercast v word_ty in
        let c_int = Llvm.const_pointercast crate_ptr word_ty in
        Llvm.const_sub v_int c_int
        in
      *)

      match stmts with
          [] -> terminate llbuilder block_id
        | head::tail ->

            iflog (fun _ ->
                     log sem_cx "trans_stmt: %a" Ast.sprintf_stmt head);

            let trans_tail_with_builder llbuilder' : unit =
              trans_stmts block_id llbuilder' tail terminate
            in
            let trans_tail () = trans_tail_with_builder llbuilder in

            match head.node with
                Ast.STMT_init_tup (dest, atoms) ->
                  let zero = const_i32 0 in
                  let lldest = trans_lval dest in
                  let trans_tup_atom idx (_, _, atom) =
                    let indices = [| zero; const_i32 idx |] in
                    let gep_id = anon_llid "init_tup_gep" in
                    let ptr =
                      Llvm.build_gep lldest indices gep_id llbuilder
                    in
                    ignore (Llvm.build_store (trans_atom atom) ptr llbuilder)
                  in
                  Array.iteri trans_tup_atom atoms;
                  trans_tail ()

              | Ast.STMT_copy (dest, src) ->
                  let llsrc = trans_expr src in
                  let lldest = trans_lval dest in
                  ignore (Llvm.build_store llsrc lldest llbuilder);
                  trans_tail ()

              | Ast.STMT_call (dest, fn, args) ->
                  let llargs = Array.map trans_atom args in
                  let lldest = trans_lval dest in
                  let llfn = trans_lval fn in
                  let llallargs = Array.append [| lldest; lltask |] llargs in
                  let llrv = build_call llfn llallargs "" llbuilder in
                    Llvm.set_instruction_call_conv Llvm.CallConv.c llrv;
                    trans_tail ()

              | Ast.STMT_if sif ->
                  let llexpr = trans_expr sif.Ast.if_test in
                  let (llnext, llnextbuilder) = new_block None "next" in
                  let branch_to_next llbuilder' _ =
                    ignore (Llvm.build_br llnext llbuilder')
                  in
                  let llthen = trans_block sif.Ast.if_then branch_to_next in
                  let llelse =
                    match sif.Ast.if_else with
                        None -> llnext
                      | Some if_else -> trans_block if_else branch_to_next
                  in
                  ignore (Llvm.build_cond_br llexpr llthen llelse llbuilder);
                  trans_tail_with_builder llnextbuilder

              | Ast.STMT_ret atom_opt ->
                  begin
                    match atom_opt with
                        None -> ()
                      | Some atom ->
                          ignore (Llvm.build_store (trans_atom atom)
                                    lloutptr llbuilder)
                  end;
                  let llbuilder = exit_block llbuilder block_id in
                    ignore (Llvm.build_ret_void llbuilder)

              | Ast.STMT_fail ->
                  trans_fail llbuilder lltask "explicit failure" head.id

              | Ast.STMT_log a ->
                  begin
                    match Semant.atom_type sem_cx a with
                        (* NB: If you extend this, be sure to update the
                         * typechecking code in type.ml as well. *)
                        Ast.TY_str -> trans_log_str a
                      | Ast.TY_int | Ast.TY_uint | Ast.TY_bool | Ast.TY_char
                      | Ast.TY_mach (TY_u8) | Ast.TY_mach (TY_u16)
                      | Ast.TY_mach (TY_u32) | Ast.TY_mach (TY_i8)
                      | Ast.TY_mach (TY_i16) | Ast.TY_mach (TY_i32) ->
                          trans_log_int a
                      | _ -> Semant.bugi sem_cx head.id
                          "unimplemented logging type"
                  end;
                  trans_tail ()

              | Ast.STMT_check_expr expr ->
                  let llexpr = trans_expr expr in
                  let (llfail, llfailbuilder) = new_block None "fail" in
                  let reason = Ast.fmt_to_str Ast.fmt_expr expr in
                  trans_fail llfailbuilder lltask reason head.id;
                  let (llok, llokbuilder) = new_block None "ok" in
                  ignore (Llvm.build_cond_br llexpr llok llfail llbuilder);
                  trans_tail_with_builder llokbuilder

              | Ast.STMT_init_str (dst, str) ->
                  let d = trans_lval dst in
                  let s = static_str str in
                  let len =
                    Llvm.const_int word_ty ((String.length str) + 1)
                  in
                    upcall llbuilder lltask "upcall_new_str"
                      (Some d) [| s; len |];
                    trans_tail ()

              | _ -> trans_stmts block_id llbuilder tail terminate

    (* 
     * Translates an AST block to one or more LLVM basic blocks and returns
     * the first basic block. The supplied callback is expected to add a
     * terminator instruction.
     *)

    and trans_block
        ({ node = (stmts:Ast.stmt array); id = id }:Ast.block)
        (terminate:Llvm.llbuilder -> node_id -> unit)
        : Llvm.llbasicblock =
      let (llblock, llbuilder) = new_block (Some id) "bb" in
        trans_stmts id llbuilder (Array.to_list stmts) terminate;
        llblock
    in

    (* "Falling off the end" of a function needs to turn into an explicit
     * return instruction. *)
    let default_terminate llbuilder block_id =
      let llbuilder = exit_block llbuilder block_id in
        ignore (Llvm.build_ret_void llbuilder)
    in

    (* Build up the first body block, and link it to the end of the
     * initialization block. *)
    let llbodyblock = (trans_block body default_terminate) in
      ignore (Llvm.build_br llbodyblock llinitbuilder)
  in

  let trans_mod_item
      (_:Ast.ident)
      { node = { Ast.decl_item = (item:Ast.mod_item') }; id = id }
      : unit =
    match item with
        Ast.MOD_ITEM_fn fn -> trans_fn fn id
      | _ -> ()
  in

  let exit_task_glue =
    (* The exit-task glue does not get called.
     * 
     * Rather, control arrives at it by *returning* to the first
     * instruction of it, when control falls off the end of the task's
     * root function.
     * 
     * There is a "fake" frame set up by the runtime, underneath us,
     * that we find ourselves in. This frame has the shape of a frame
     * entered with 2 standard arguments (outptr + taskptr), then a
     * retpc and N callee-saves sitting on the stack; all this is under
     * ebp. Then there are 2 *outgoing* args at sp[0] and sp[1].
     * 
     * All these are fake except the taskptr, which is the one bit we
     * want. So we construct an equally fake cdecl llvm signature here
     * to crudely *get* the taskptr that's sitting 2 words up from sp,
     * and pass it to upcall_exit.
     * 
     * The latter never returns.
     *)
    let llty = fn_ty void_ty [| task_ptr_ty |] in
    let llfn = Llvm.declare_function "rust_exit_task_glue" llty llmod in
    let lltask = Llvm.param llfn 0 in
    let llblock = Llvm.append_block llctx "body" llfn in
    let llbuilder = Llvm.builder_at_end llctx llblock in
      trans_upcall llbuilder lltask "upcall_exit" None [||];
      ignore (Llvm.build_ret_void llbuilder);
      llfn
  in

    try
      let crate' = crate.node in
      let items = snd (crate'.Ast.crate_items) in
        Hashtbl.iter declare_mod_item items;
        Hashtbl.iter trans_mod_item items;
        Llfinal.finalize_module
          llctx llmod abi asm_glue exit_task_glue crate_ptr;
        llmod
    with e -> Llvm.dispose_module llmod; raise e
;;

(*
 * Local Variables:
 * fill-column: 78;
 * indent-tabs-mode: nil
 * buffer-file-coding-system: utf-8-unix
 * compile-command: "make -k -C ../.. 2>&1 | sed -e 's/\\/x\\//x:\\//g'";
 * End:
 *)

