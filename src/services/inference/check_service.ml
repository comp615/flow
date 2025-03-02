(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

type module_ref = string

type require = module_ref * ALoc.t Nel.t * Modulename.t

type check_file =
  File_key.t ->
  require list ->
  (ALoc.t, ALoc.t) Flow_ast.Program.t ->
  Loc.t Flow_ast.Comment.t list ->
  File_sig.With_ALoc.t ->
  Docblock.t ->
  ALoc.table Lazy.t ->
  Context.t * (ALoc.t, ALoc.t * Type.t) Flow_ast.Program.t

(* Check will lazily create types for the checked file's dependencies. These
 * types are created in the dependency's context and need to be copied into the
 * checked file's context.
 *
 * This visitor walks a type in the dependency's context (src_cx) and copies
 * any tvars, property maps, evaluated types, etc. into the check file's context
 * (dst_cx).
 *
 * When calculating a direct dependency's types, we might also need to construct
 * types for a transitive dependency. These types are similarly created in the
 * transitive dependency's context, then copied into the dependency's context,
 * and so on.
 *
 * Finally, due to cycles, it's possile that src_cx and dst_cx share the same
 * component cx, and thus have the same tvar graph, property maps, etc. Happily,
 * this does not complicate the implementation, as the mem checks and early
 * returns on each method override are sufficient.
 *
 * Crucially, this copying process is shallow. We only copy what is necessary to
 * interpret a given type. *)
let copier =
  let open Type in
  let open Constraint in
  object (self)
    inherit [Context.t] Type_visitor.t as super

    (* Copying a tvar produces a FullyResolved tvar in the dst cx, which
     * contains an unevaluated thunk. The laziness here makes the copying
     * shallow. Note that the visitor stops at root tvars here and only resumes
     * if the thunk is forced. *)
    method! tvar src_cx pole dst_cx r id =
      let dst_graph = Context.graph dst_cx in
      if IMap.mem id dst_graph then
        dst_cx
      else
        let (root_id, constraints) = Context.find_constraints src_cx id in
        if id == root_id then (
          let constraints =
            lazy
              (let t =
                 match Lazy.force constraints with
                 | Unresolved { lower; _ } ->
                   lazy
                     (let ts = TypeMap.keys lower |> List.filter Type.is_proper_def in
                      match ts with
                      | [t] -> t
                      | t0 :: t1 :: ts -> UnionT (r, UnionRep.make t0 t1 ts)
                      | [] -> Unsoundness.merged_any r
                     )
                 | Resolved (_, t) -> lazy t
                 | FullyResolved (_, t) -> t
               in
               let t =
                 lazy
                   (let t = Lazy.force t in
                    let (_ : Context.t) = self#type_ src_cx pole dst_cx t in
                    t
                   )
               in
               FullyResolved (unknown_use, t)
              )
          in
          let node = Root { rank = 0; constraints } in
          Context.set_graph dst_cx (IMap.add id node dst_graph);
          dst_cx
        ) else (
          Context.set_graph dst_cx (IMap.add id (Goto root_id) dst_graph);
          self#tvar src_cx pole dst_cx r root_id
        )

    method! props src_cx pole dst_cx id =
      let dst_property_maps = Context.property_maps dst_cx in
      if Properties.Map.mem id dst_property_maps then
        dst_cx
      else
        let props = Context.find_props src_cx id in
        Context.set_property_maps dst_cx (Properties.Map.add id props dst_property_maps);
        super#props src_cx pole dst_cx id

    method! call_prop src_cx pole dst_cx id =
      let dst_call_props = Context.call_props dst_cx in
      if IMap.mem id dst_call_props then
        dst_cx
      else
        let t = Context.find_call src_cx id in
        Context.set_call_props dst_cx (IMap.add id t dst_call_props);
        super#call_prop src_cx pole dst_cx id

    method! exports src_cx pole dst_cx id =
      let dst_export_maps = Context.export_maps dst_cx in
      if Exports.Map.mem id dst_export_maps then
        dst_cx
      else
        let map = Context.find_exports src_cx id in
        Context.set_export_maps dst_cx (Exports.Map.add id map dst_export_maps);
        super#exports src_cx pole dst_cx id

    method! eval_id src_cx pole dst_cx id =
      match Eval.Map.find_opt id (Context.evaluated src_cx) with
      | None -> dst_cx
      | Some t ->
        let dst_evaluated = Context.evaluated dst_cx in
        if Eval.Map.mem id dst_evaluated then
          dst_cx
        else (
          Context.set_evaluated dst_cx (Eval.Map.add id t dst_evaluated);
          super#eval_id src_cx pole dst_cx id
        )
  end

let copy_into dst_cx src_cx t =
  let (_ : Context.t) = copier#type_ src_cx Polarity.Positive dst_cx t in
  ()

let unknown_module_t cx mref provider =
  let react_server_module_err = provider = Modulename.String Type.react_server_module_ref in
  let desc = Reason.RCustom mref in
  let m_name =
    match provider with
    | Modulename.String ("react" | "React") when Context.in_react_server_component_file cx ->
      Type.react_server_module_ref
    | _ -> Modulename.to_string provider
  in
  let m_name = Reason.internal_module_name m_name in
  fun loc ->
    if react_server_module_err then
      Flow_js.add_output cx (Error_message.EImportInternalReactServerModule loc);
    let reason = Reason.mk_reason desc loc in
    Flow_js_utils.lookup_builtin_strict cx m_name reason

let unchecked_module_t cx mref =
  let desc = Reason.RUntypedModule mref in
  let m_name = Reason.internal_module_name mref in
  fun loc ->
    let reason = Reason.mk_reason desc loc in
    let default = Type.(AnyT (reason, Untyped)) in
    Flow_js_utils.lookup_builtin_with_default cx m_name default

let get_lint_severities metadata options =
  let lint_severities = Options.lint_severities options in
  let strict_mode = Options.strict_mode options in
  Merge_js.get_lint_severities metadata strict_mode lint_severities

module ConsGen : Type_sig_merge.CONS_GEN = struct
  include Flow_js

  let dst_cx_ref = ref None

  let set_dst_cx cx = dst_cx_ref := Some cx

  let unresolved_tvar = Tvar.mk_no_wrap

  (* Helper to create a lazy type. The returned tvar contains a lazy thunk which
   * evaluates to a type. While the lazy thunk is under evaluation, we swap out
   * the tvar's constraint with a fresh unresolved root. This deals with the
   * recursive case where forcing `resolved` loops back to the tvar being defined.
   * *)
  let mk_lazy_tvar cx reason f =
    let open Type in
    let open Constraint in
    let id = Reason.mk_id () in
    let tvar = OpenT (reason, id) in
    let constraints =
      lazy
        (let node = new_unresolved_root () in
         Context.add_tvar cx id node;
         f tvar;
         Lazy.force (Context.find_graph cx id)
        )
    in
    Context.add_tvar cx id (Root { rank = 0; constraints });
    tvar

  let mk_sig_tvar cx reason resolved =
    let f tvar =
      let t = Lazy.force resolved in
      Flow_js.unify cx tvar t
    in
    mk_lazy_tvar cx reason f

  let assert_export_is_type cx reason name t =
    let open Type in
    let f tvar =
      let name = Reason.OrdinaryName name in
      Flow_js.flow cx (t, AssertExportIsTypeT (reason, name, tvar))
    in
    mk_lazy_tvar cx reason f

  let get_prop cx use_op reason propname t =
    Tvar.mk_no_wrap_where cx reason (fun tout ->
        Flow_js.flow cx (t, Type.GetPropT (use_op, reason, Type.Named (reason, propname), tout))
    )

  let get_elem cx use_op reason ~key t =
    Tvar.mk_no_wrap_where cx reason (fun tout ->
        Flow_js.flow cx (t, Type.GetElemT (use_op, reason, key, tout))
    )

  let qualify_type cx use_op reason (reason_name, name) t =
    let open Type in
    let f tvar =
      Flow_js.flow cx (t, GetPropT (use_op, reason, Named (reason_name, name), open_tvar tvar))
    in
    mk_lazy_tvar cx reason f

  let mk_type_reference cx reason c =
    let open Type in
    let f tvar =
      let type_t = DefT (reason, bogus_trust (), TypeT (InstanceKind, tvar)) in
      Flow_js.flow cx (c, UseT (unknown_use, type_t))
    in
    let tvar = mk_lazy_tvar cx reason f in
    AnnotT (reason, tvar, false)

  let cjs_require cx module_t reason is_strict =
    Tvar.mk_where cx reason (fun tout ->
        Flow_js.flow cx (module_t, Type.CJSRequireT (reason, tout, is_strict))
    )

  let export_named cx reason kind named module_t =
    Tvar.mk_where cx reason (fun tout ->
        Flow_js.flow cx (module_t, Type.ExportNamedT (reason, named, kind, tout))
    )

  let cjs_extract_named_exports cx reason local_module t =
    Tvar.mk_where cx reason (fun tout ->
        Flow_js.flow cx (t, Type.CJSExtractNamedExportsT (reason, local_module, tout))
    )

  let import_default cx reason kind local mref is_strict t =
    Tvar.mk_where cx reason (fun tout ->
        Flow_js.flow cx (t, Type.ImportDefaultT (reason, kind, (local, mref), tout, is_strict))
    )

  let import_named cx reason kind remote mref is_strict module_t =
    Tvar.mk_where cx reason (fun tout ->
        Flow_js.flow cx (module_t, Type.ImportNamedT (reason, kind, remote, mref, tout, is_strict))
    )

  let import_ns cx reason is_strict module_t =
    Tvar.mk_where cx reason (fun tout ->
        Flow_js.flow cx (module_t, Type.ImportModuleNsT (reason, tout, is_strict))
    )

  let import_typeof cx reason export_name ns_t =
    Tvar.mk_where cx reason (fun tout ->
        Flow_js.flow cx (ns_t, Type.ImportTypeofT (reason, export_name, tout))
    )

  let specialize cx t use_op reason_op reason_tapp ts =
    Tvar.mk_where cx reason_op (fun tout ->
        Flow_js.flow cx (t, Type.SpecializeT (use_op, reason_op, reason_tapp, None, ts, tout))
    )

  let copy_named_exports cx ~from_ns reason ~module_t =
    Tvar.mk_where cx reason (fun tout ->
        Flow_js.flow cx (from_ns, Type.CopyNamedExportsT (reason, module_t, tout))
    )

  let copy_type_exports cx ~from_ns reason ~module_t =
    Tvar.mk_where cx reason (fun tout ->
        Flow_js.flow cx (from_ns, Type.CopyTypeExportsT (reason, module_t, tout))
    )

  let unary_minus cx reason t =
    Tvar.mk_where cx reason (fun tout -> Flow_js.flow cx (t, Type.UnaryMinusT (reason, tout)))

  let unary_not cx reason t =
    Tvar.mk_no_wrap_where cx reason (fun tout -> Flow_js.flow cx (t, Type.NotT (reason, tout)))

  let mixin cx reason t =
    Tvar.mk_where cx reason (fun tout -> Flow_js.flow cx (t, Type.MixinT (reason, tout)))

  let object_spread cx use_op reason target state t =
    let tool = Type.Object.(Resolve Next) in
    Tvar.mk_where cx reason (fun tout ->
        Flow_js.flow
          cx
          (t, Type.(ObjKitT (use_op, reason, tool, Object.Spread (target, state), tout)))
    )

  let obj_test_proto cx reason l =
    Tvar.mk_where cx reason (fun proto -> Flow_js.flow cx (l, Type.ObjTestProtoT (reason, proto)))

  let obj_rest cx reason xs t =
    Tvar.mk_where cx reason (fun tout ->
        Flow_js.flow cx (t, Type.ObjRestT (reason, xs, tout, Reason.mk_id ()))
    )

  let arr_rest cx use_op reason i t =
    Tvar.mk_where cx reason (fun tout ->
        Flow_js.flow cx (t, Type.ArrRestT (use_op, reason, i, tout))
    )
end

[@@@warning "-60"]

(* Don't use Flow_js directly from Check_service. Instead, encode the respective
 * logic in ConsGen. *)
module Flow_js = struct end

[@@@warning "+60"]

(* This function is designed to be applied up to the unit argument and returns a
 * function which can be called repeatedly. The returned function closes over an
 * environment which defines caches that can be re-used when checking multiple
 * files. *)
let mk_check_file ~options ~reader ~cache () =
  let open Type_sig_collections in
  let module ConsGen = ( val if Options.new_merge options then
                               (module Annotation_inference.ConsGen)
                             else
                               (module ConsGen) : Type_sig_merge.CONS_GEN
                       )
  in
  let module Merge = Type_sig_merge.Make (ConsGen) in
  let module Pack = Type_sig_pack in
  let module Bin = Type_sig_bin in
  let module Heap = SharedMem.NewAPI in
  let audit = Expensive.ok in

  let get_file = Module_heaps.Reader_dispatcher.get_file ~reader ~audit in
  let get_type_sig_unsafe = Parsing_heaps.Reader_dispatcher.get_type_sig_addr_unsafe ~reader in
  let get_info_unsafe = Module_heaps.Reader_dispatcher.get_info_unsafe ~reader ~audit in
  let get_aloc_table_unsafe = Parsing_heaps.Reader_dispatcher.get_aloc_table_unsafe ~reader in
  let find_leader = Context_heaps.Reader_dispatcher.find_leader ~reader in
  let get_resolved_requires_unsafe =
    Module_heaps.Reader_dispatcher.get_resolved_requires_unsafe ~reader ~audit
  in

  let master_cx = Context_heaps.Reader_dispatcher.find_master ~reader in

  let base_metadata = Context.metadata_of_options options in

  (* Create a merging context for a dependency of a checked file. These contexts
   * are used when converting signatures to types. *)
  let create_dep_cx file_key docblock ccx =
    let metadata = Context.docblock_overrides docblock base_metadata in
    let module_ref = Reason.OrdinaryName (Files.module_ref file_key) in
    let aloc_table = lazy (get_aloc_table_unsafe file_key) in
    Context.make ccx metadata file_key aloc_table module_ref Context.Merging
  in

  (* Create a type representing the exports of a dependency. For checked
   * dependencies, we will create a "sig tvar" with a lazy thunk that evaluates
   * to a ModuleT type. *)
  let rec dep_module_t cx mref provider =
    match get_file provider with
    | None -> unknown_module_t cx mref provider
    | Some (File_key.ResourceFile f) -> Merge.merge_resource_module_t cx f
    | Some dep_file ->
      let { Module_heaps.checked; parsed; _ } = get_info_unsafe dep_file in
      if checked && parsed then
        sig_module_t cx dep_file
      else
        unchecked_module_t cx mref
  and sig_module_t cx file_key _loc =
    let file =
      Check_cache.find_or_create cache ~find_leader ~master_cx ~create_file:dep_file file_key
    in
    let t = file.Type_sig_merge.exports () in
    copy_into cx file.Type_sig_merge.cx t;
    t
  (* Create a Type_sig_merge.file record for a dependency, which we use to
   * convert signatures into types. This function reads the signature for a file
   * from shared memory and creates thunks (either lazy tvars or lazy types)
   * that resolve to types. *)
  and dep_file file_key ccx =
    let source = Some file_key in

    let aloc (loc : Locs.index) = ALoc.ALocRepresentationDoNotUse.make_keyed source (loc :> int) in

    let aloc =
      if Options.abstract_locations options then
        aloc
      else
        let aloc_table = lazy (get_aloc_table_unsafe file_key) in
        (fun loc -> aloc loc |> ALoc.to_loc aloc_table |> ALoc.of_loc)
    in

    let deserialize x = Marshal.from_string x 0 in

    let file_addr = get_type_sig_unsafe file_key in

    let buf = Heap.type_sig_buf (Heap.file_type_sig file_addr) in

    let docblock = Heap.file_docblock file_addr |> Heap.read_docblock |> deserialize in

    let cx = create_dep_cx file_key docblock ccx in

    let dependencies =
      let { Module_heaps.resolved_modules; _ } = get_resolved_requires_unsafe file_key in
      let f buf pos =
        let mref = Bin.read_str buf pos in
        let provider = SMap.find mref resolved_modules in
        (mref, dep_module_t cx mref provider)
      in
      let pos = Bin.module_refs buf in
      Bin.read_tbl_generic f buf pos Module_refs.init
    in

    let exports file_rec =
      let file_loc = ALoc.of_loc { Loc.none with Loc.source = Some file_key } in
      let reason = Reason.(mk_reason RExports file_loc) in
      let type_export buf pos =
        lazy
          (Bin.read_hashed Bin.read_type_export buf pos
          |> Pack.map_type_export aloc
          |> Merge.merge_type_export (Lazy.force file_rec) reason
          )
      in
      let cjs_exports buf pos =
        lazy
          (Bin.read_hashed Bin.read_packed buf pos
          |> Pack.map_packed aloc
          |> Merge.merge (Lazy.force file_rec)
          )
      in
      let es_export buf pos =
        lazy
          (Bin.read_hashed Bin.read_es_export buf pos
          |> Pack.map_export aloc
          |> Merge.merge_export (Lazy.force file_rec)
          )
      in
      let cjs_module buf pos =
        let (Pack.CJSModuleInfo { type_export_keys; type_stars; strict }) =
          Bin.cjs_module_info buf pos
          |> Bin.read_hashed Bin.read_cjs_info buf
          |> Pack.map_cjs_module_info aloc
        in
        let type_exports = Bin.cjs_module_type_exports buf pos |> Bin.read_tbl type_export buf in
        let exports = Bin.cjs_module_exports buf pos |> Bin.read_opt cjs_exports buf in
        let type_exports =
          let f acc name export = SMap.add name export acc in
          Base.Array.fold2_exn ~init:SMap.empty ~f type_export_keys type_exports
        in
        Type_sig_merge.CJSExports { type_exports; exports; type_stars; strict }
      in
      let es_module buf pos =
        let (Pack.ESModuleInfo { type_export_keys; export_keys; type_stars; stars; strict }) =
          Bin.es_module_info buf pos
          |> Bin.read_hashed Bin.read_es_info buf
          |> Pack.map_es_module_info aloc
        in
        let type_exports = Bin.es_module_type_exports buf pos |> Bin.read_tbl type_export buf in
        let exports = Bin.es_module_exports buf pos |> Bin.read_tbl es_export buf in
        let type_exports =
          let f acc name export = SMap.add name export acc in
          Base.Array.fold2_exn ~init:SMap.empty ~f type_export_keys type_exports
        in
        let exports =
          let f acc name export = SMap.add name export acc in
          Base.Array.fold2_exn ~init:SMap.empty ~f export_keys exports
        in
        Type_sig_merge.ESExports { type_exports; exports; type_stars; stars; strict }
      in
      let resolved =
        lazy
          (Bin.module_kind buf
          |> Bin.read_module_kind cjs_module es_module buf
          |> Merge.merge_exports (Lazy.force file_rec) reason
          )
      in
      let t = ConsGen.mk_sig_tvar cx reason resolved in
      (fun () -> t)
    in

    let local_def file_rec buf pos =
      let thunk =
        lazy
          (let def = Pack.map_packed_def aloc (Bin.read_local_def buf pos) in
           let loc = Type_sig.def_id_loc def in
           let name = Type_sig.def_name def in
           let reason = Type_sig_merge.def_reason def in
           let resolved = lazy (Merge.merge_def (Lazy.force file_rec) reason def) in
           let t = ConsGen.mk_sig_tvar cx reason resolved in
           (loc, name, t)
          )
      in
      (fun () -> Lazy.force thunk)
    in

    let remote_ref file_rec buf pos =
      let thunk =
        lazy
          (let remote_ref = Pack.map_remote_ref aloc (Bin.read_remote_ref buf pos) in
           let loc = Pack.remote_ref_loc remote_ref in
           let name = Pack.remote_ref_name remote_ref in
           let reason = Type_sig_merge.remote_ref_reason remote_ref in
           let resolved = lazy (Merge.merge_remote_ref (Lazy.force file_rec) reason remote_ref) in
           let t = ConsGen.mk_sig_tvar cx reason resolved in
           (loc, name, t)
          )
      in
      (fun () -> Lazy.force thunk)
    in

    let pattern_def file_rec buf pos =
      lazy (Bin.read_packed buf pos |> Pack.map_packed aloc |> Merge.merge (Lazy.force file_rec))
    in

    let pattern file_rec buf pos =
      lazy
        (Bin.read_pattern buf pos
        |> Pack.map_pattern aloc
        |> Merge.merge_pattern (Lazy.force file_rec)
        )
    in

    let local_defs file_rec =
      let pos = Bin.local_defs buf in
      Bin.read_tbl_generic (local_def file_rec) buf pos Local_defs.init
    in

    let remote_refs file_rec =
      let pos = Bin.remote_refs buf in
      Bin.read_tbl_generic (remote_ref file_rec) buf pos Remote_refs.init
    in

    let pattern_defs file_rec =
      let pos = Bin.pattern_defs buf in
      Bin.read_tbl_generic (pattern_def file_rec) buf pos Pattern_defs.init
    in

    let patterns file_rec =
      let pos = Bin.patterns buf in
      Bin.read_tbl_generic (pattern file_rec) buf pos Patterns.init
    in

    let rec file_rec =
      lazy
        {
          Type_sig_merge.key = file_key;
          cx;
          dependencies;
          exports = exports file_rec;
          local_defs = local_defs file_rec;
          remote_refs = remote_refs file_rec;
          pattern_defs = pattern_defs file_rec;
          patterns = patterns file_rec;
        }
    in
    Lazy.force file_rec
  in

  let connect_require cx (mref, locs, provider) =
    let module_t = dep_module_t cx mref provider in
    let connect loc =
      let module_t = module_t loc in
      let (_, require_id) = Context.find_require cx loc in
      ConsGen.resolve_id cx require_id module_t
    in
    Nel.iter connect locs
  in

  fun file_key requires ast comments file_sig docblock aloc_table ->
    let ccx = Context.make_ccx master_cx in
    let metadata = Context.docblock_overrides docblock base_metadata in
    let module_ref = Reason.OrdinaryName (Files.module_ref file_key) in
    let cx = Context.make ccx metadata file_key aloc_table module_ref Context.Checking in
    ConsGen.set_dst_cx cx;
    let infer_ast =
      match Context.env_mode cx with
      | Options.SSAEnv -> Type_inference_js.NewEnvInference.infer_ast
      | _ -> Type_inference_js.infer_ast
    in
    let lint_severities = get_lint_severities metadata options in
    Type_inference_js.add_require_tvars ~unresolved_tvar:ConsGen.unresolved_tvar cx file_sig;
    List.iter (connect_require cx) requires;
    let typed_ast = infer_ast cx file_key comments ast ~lint_severities in
    Merge_js.post_merge_checks cx master_cx ast typed_ast metadata file_sig;
    (cx, typed_ast)
