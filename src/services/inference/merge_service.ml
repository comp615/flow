(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Utils_js

type duration = float

type 'a unit_result = ('a, ALoc.t * Error_message.internal_error) result

type merge_result = Error_suppressions.t * duration

type check_type_result =
  Context.t
  * Type_sig_collections.Locs.index Packed_type_sig.Module.t
  * File_sig.With_ALoc.t
  * (ALoc.t, ALoc.t * Type.t) Flow_ast.Program.t

type check_error_result =
  Flow_error.ErrorSet.t
  * Flow_error.ErrorSet.t
  * Error_suppressions.t
  * Coverage_response.file_coverage
  * duration

type check_result = check_type_result * check_error_result

type sig_opts_data = {
  skipped_count: int;
  sig_new_or_changed: FilenameSet.t;
}

type 'a merge_results = (File_key.t * bool * 'a unit_result) list * sig_opts_data

type 'a merge_job =
  worker_mutator:Context_heaps.Merge_context_mutator.worker_mutator ->
  options:Options.t ->
  reader:Mutator_state_reader.t ->
  File_key.t Nel.t ->
  bool * 'a unit_result

let sig_hash ~root =
  let open Type_sig_collections in
  let open Type_sig_hash in
  let module Heap = SharedMem.NewAPI in
  let module P = Type_sig_pack in
  let module Bin = Type_sig_bin in
  let hash_file_key file_key =
    let file_string =
      match file_key with
      | File_key.LibFile path
      | File_key.SourceFile path
      | File_key.JsonFile path
      | File_key.ResourceFile path ->
        Files.relative_path (Path.to_string root) path
      | File_key.Builtins -> File_key.to_string file_key
    in
    Xx.hash file_string 0L
  in

  (* The module type of a resource dependency only depends on the file
   * extension. See Type_sig_merge.merge_resource_module_t *)
  let resource_dep f =
    let ext =
      match Utils_js.extension_of_filename f with
      | Some ext -> ext
      | None -> failwith "resource file without extension"
    in
    let hash = Xx.hash ext 0L in
    Resource (fun () -> hash)
  in

  (* A dependency which is not part of the cycle has already been merged and its
   * hashes are stored in shared memory. We can create a checked_dep record
   * containing accessors to those hashes.
   *
   * It might be useful to cache this for re-use across files in a component or
   * components in a merge batch, but this performs well enough without caching
   * for now. *)
  let acyclic_dep =
    let read_hash buf pos () = Bin.read_hash buf pos in
    let cjs_module file_key buf pos =
      let filename = Fun.const (hash_file_key file_key) in
      let info_pos = Bin.cjs_module_info buf pos in
      let (P.CJSModuleInfo { type_export_keys; type_stars = _; strict = _ }) =
        Bin.read_hashed Bin.read_cjs_info buf info_pos
      in
      let type_exports = Bin.cjs_module_type_exports buf pos |> Bin.read_tbl read_hash buf in
      let exports = Bin.cjs_module_exports buf pos |> Bin.read_opt read_hash buf in
      let ns = read_hash buf info_pos in
      let type_exports =
        let f acc name export = SMap.add name export acc in
        Base.Array.fold2_exn ~init:SMap.empty ~f type_export_keys type_exports
      in
      CJS { filename; type_exports; exports; ns }
    in
    let es_module file_key buf pos =
      let filename = Fun.const (hash_file_key file_key) in
      let info_pos = Bin.es_module_info buf pos in
      let (P.ESModuleInfo { type_export_keys; export_keys; type_stars = _; stars = _; strict = _ })
          =
        Bin.read_hashed Bin.read_es_info buf info_pos
      in
      let type_exports = Bin.es_module_type_exports buf pos |> Bin.read_tbl read_hash buf in
      let exports = Bin.es_module_exports buf pos |> Bin.read_tbl read_hash buf in
      let ns = read_hash buf info_pos in
      let type_exports =
        let f acc name export = SMap.add name export acc in
        Base.Array.fold2_exn ~init:SMap.empty ~f type_export_keys type_exports
      in
      let exports =
        let f acc name export = SMap.add name export acc in
        Base.Array.fold2_exn ~init:SMap.empty ~f export_keys exports
      in
      ES { filename; type_exports; exports; ns }
    in
    fun ~reader dep_key ->
      let file_addr = Parsing_heaps.Reader_dispatcher.get_type_sig_addr_unsafe ~reader dep_key in
      let buf = Heap.type_sig_buf (Heap.file_type_sig file_addr) in
      Bin.read_module_kind (cjs_module dep_key) (es_module dep_key) buf (Bin.module_kind buf)
  in

  (* Create a Type_sig_hash.checked_dep record for a file in the merged component. *)
  let cyclic_dep file_key file_addr file =
    let filename = Fun.const (hash_file_key file_key) in

    let type_export buf pos =
      let init_hash = Bin.read_hashed Bin.hash_serialized buf pos in
      let export = Bin.read_hashed Bin.read_type_export buf pos in
      let read_hash () = Bin.read_hash buf pos in
      let write_hash hash = Bin.write_hash buf pos hash in
      let visit edge _dep_edge = visit_type_export edge file export in
      write_hash init_hash;
      Cycle_hash.create_node visit read_hash write_hash
    in

    let cjs_exports buf pos =
      let init_hash = Bin.read_hashed Bin.hash_serialized buf pos in
      let exports = Bin.read_hashed Bin.read_packed buf pos in
      let read_hash () = Bin.read_hash buf pos in
      let write_hash hash = Bin.write_hash buf pos hash in
      let visit edge dep_edge = visit_packed edge dep_edge file exports in
      write_hash init_hash;
      Cycle_hash.create_node visit read_hash write_hash
    in

    let es_export buf pos =
      let init_hash = Bin.read_hashed Bin.hash_serialized buf pos in
      let export = Bin.read_hashed Bin.read_es_export buf pos in
      let read_hash () = Bin.read_hash buf pos in
      let write_hash hash = Bin.write_hash buf pos hash in
      let visit edge dep_edge = visit_export edge dep_edge file export in
      write_hash init_hash;
      Cycle_hash.create_node visit read_hash write_hash
    in

    let cjs_module buf pos =
      let info_pos = Bin.cjs_module_info buf pos in
      let init_hash = Bin.read_hashed Bin.hash_serialized buf info_pos in
      let (P.CJSModuleInfo { type_export_keys; type_stars; strict = _ }) =
        Bin.read_hashed Bin.read_cjs_info buf info_pos
      in
      let type_exports = Bin.cjs_module_type_exports buf pos |> Bin.read_tbl type_export buf in
      let exports = Bin.cjs_module_exports buf pos |> Bin.read_opt cjs_exports buf in
      let ns =
        let visit edge dep_edge =
          Array.iter edge type_exports;
          Option.iter edge exports;
          List.iter (fun (_, index) -> edge_import_ns edge dep_edge file index) type_stars
        in
        let read_hash () = Bin.read_hash buf info_pos in
        let write_hash hash = Bin.write_hash buf info_pos hash in
        write_hash init_hash;
        Cycle_hash.create_node visit read_hash write_hash
      in
      let type_exports =
        let f acc name export = SMap.add name export acc in
        Base.Array.fold2_exn ~init:SMap.empty ~f type_export_keys type_exports
      in
      CJS { filename; type_exports; exports; ns }
    in

    let es_module buf pos =
      let info_pos = Bin.es_module_info buf pos in
      let init_hash = Bin.read_hashed Bin.hash_serialized buf info_pos in
      let (P.ESModuleInfo { type_export_keys; export_keys; type_stars; stars; strict = _ }) =
        Bin.read_hashed Bin.read_es_info buf info_pos
      in
      let type_exports = Bin.es_module_type_exports buf pos |> Bin.read_tbl type_export buf in
      let exports = Bin.es_module_exports buf pos |> Bin.read_tbl es_export buf in
      let ns =
        let visit edge dep_edge =
          Array.iter edge type_exports;
          Array.iter edge exports;
          List.iter (fun (_, index) -> edge_import_ns edge dep_edge file index) type_stars;
          List.iter (fun (_, index) -> edge_import_ns edge dep_edge file index) stars
        in
        let read_hash () = Bin.read_hash buf info_pos in
        let write_hash hash = Bin.write_hash buf info_pos hash in
        write_hash init_hash;
        Cycle_hash.create_node visit read_hash write_hash
      in
      let type_exports =
        let f acc name export = SMap.add name export acc in
        Base.Array.fold2_exn ~init:SMap.empty ~f type_export_keys type_exports
      in
      let exports =
        let f acc name export = SMap.add name export acc in
        Base.Array.fold2_exn ~init:SMap.empty ~f export_keys exports
      in
      ES { filename; type_exports; exports; ns }
    in

    let buf = Heap.type_sig_buf (Heap.file_type_sig file_addr) in
    Bin.read_module_kind cjs_module es_module buf (Bin.module_kind buf)
  in

  let file_dependency ~reader component_rec component_map provider =
    let open Module_heaps in
    match Reader_dispatcher.get_file ~reader ~audit:Expensive.ok provider with
    | None -> Unchecked
    | Some (File_key.ResourceFile f) -> resource_dep f
    | Some dep ->
      let info = Reader_dispatcher.get_info_unsafe ~reader ~audit:Expensive.ok dep in
      if info.checked && info.parsed then
        match FilenameMap.find_opt dep component_map with
        | Some i -> Cyclic (lazy (Lazy.force component_rec).(i))
        | None -> Acyclic (lazy (acyclic_dep ~reader dep))
      else
        Unchecked
  in

  (* Create a Type_sig_hash.file record for a file in the merged component. *)
  let component_file ~reader component_rec component_map file_key =
    let file_addr = Parsing_heaps.Reader_dispatcher.get_type_sig_addr_unsafe ~reader file_key in

    let buf = Heap.type_sig_buf (Heap.file_type_sig file_addr) in

    let dependencies =
      let { Module_heaps.resolved_modules; _ } =
        Module_heaps.Reader_dispatcher.get_resolved_requires_unsafe
          ~reader
          ~audit:Expensive.ok
          file_key
      in
      let f buf pos =
        let mref = Bin.read_str buf pos in
        let provider = SMap.find mref resolved_modules in
        file_dependency ~reader component_rec component_map provider
      in
      let pos = Bin.module_refs buf in
      Bin.read_tbl_generic f buf pos Module_refs.init
    in

    let local_defs file_rec =
      let f buf pos =
        let def = Bin.read_local_def buf pos in
        let hash = ref (Bin.hash_serialized buf pos) in
        let visit edge dep_edge = visit_def edge dep_edge (Lazy.force file_rec) def in
        let read_hash () = !hash in
        let write_hash = ( := ) hash in
        Cycle_hash.create_node visit read_hash write_hash
      in
      let pos = Bin.local_defs buf in
      Bin.read_tbl_generic f buf pos Local_defs.init
    in

    let remote_refs file_rec =
      let f buf pos =
        let remote_ref = Bin.read_remote_ref buf pos in
        let hash = ref (Bin.hash_serialized buf pos) in
        let visit edge dep_edge = visit_remote_ref edge dep_edge (Lazy.force file_rec) remote_ref in
        let read_hash () = !hash in
        let write_hash = ( := ) hash in
        Cycle_hash.create_node visit read_hash write_hash
      in
      let pos = Bin.remote_refs buf in
      Bin.read_tbl_generic f buf pos Remote_refs.init
    in

    let pattern_defs file_rec =
      let f buf pos =
        let def = Bin.read_packed buf pos in
        let hash = ref (Bin.hash_serialized buf pos) in
        let visit edge dep_edge = visit_packed edge dep_edge (Lazy.force file_rec) def in
        let read_hash () = !hash in
        let write_hash = ( := ) hash in
        Cycle_hash.create_node visit read_hash write_hash
      in
      let pos = Bin.pattern_defs buf in
      Bin.read_tbl_generic f buf pos Pattern_defs.init
    in

    let patterns file_rec =
      let f buf pos =
        let pattern = Bin.read_pattern buf pos in
        let hash = ref (Bin.hash_serialized buf pos) in
        let visit f _ = visit_pattern f (Lazy.force file_rec) pattern in
        let read_hash () = !hash in
        let write_hash = ( := ) hash in
        Cycle_hash.create_node visit read_hash write_hash
      in
      let pos = Bin.patterns buf in
      Bin.read_tbl_generic f buf pos Patterns.init
    in

    let rec file_rec =
      lazy
        {
          dependencies;
          local_defs = local_defs file_rec;
          remote_refs = remote_refs file_rec;
          pattern_defs = pattern_defs file_rec;
          patterns = patterns file_rec;
        }
    in

    cyclic_dep file_key file_addr (Lazy.force file_rec)
  in

  fun ~reader component ->
    (* Built a reverse lookup to detect in-cycle dependencies. *)
    let component = Array.of_list (Nel.to_list component) in
    let component_map =
      let acc = ref FilenameMap.empty in
      Array.iteri (fun i file -> acc := FilenameMap.add file i !acc) component;
      !acc
    in

    (* Create array of Type_sig_hash.checked_dep records, which we can use to
     * traverse the graph of signature dependencies. *)
    let rec component_rec =
      lazy (Array.map (component_file ~reader component_rec component_map) component)
    in

    (* Compute component hash by visiting graph starting at namespace root of
     * each file. The component hash is an unordered combination of each file's
     * hash. *)
    let cx = Cycle_hash.create_cx () in
    let component_hash = ref 0L in
    Array.iter
      (fun (CJS { ns; _ } | ES { ns; _ }) ->
        Cycle_hash.root cx ns;
        let file_hash = Cycle_hash.read_hash ns in
        component_hash := Int64.logxor file_hash !component_hash)
      (Lazy.force component_rec);
    !component_hash

(* Entry point for merging a component *)
let merge_component ~worker_mutator ~options ~reader ((leader_f, _) as component) =
  let start_time = Unix.gettimeofday () in

  (* We choose the head file as the leader, and the tail as followers. It is
   * always OK to choose the head as leader, as explained below.
   *
   * Note that cycles cannot happen between unchecked files. Why? Because files
   * in cycles must have their dependencies recorded, yet dependencies are never
   * recorded for unchecked files.
   *
   * It follows that when the head is unchecked, there are no other files! We
   * don't have to worry that some other file may be checked when the head is
   * unchecked.
   *
   * It also follows when the head is checked, the tail must be checked too! *)
  let info = Module_heaps.Mutator_reader.get_info_unsafe ~reader ~audit:Expensive.ok leader_f in
  if not info.Module_heaps.checked then
    let diff = false in
    (diff, Ok None)
  else
    let hash =
      let reader = Abstract_state_reader.Mutator_state_reader reader in
      let root = Options.root options in
      sig_hash ~root ~reader component
    in
    let metadata = Context.metadata_of_options options in
    let lint_severities = Options.lint_severities options in
    let strict_mode = Options.strict_mode options in
    let ccx = Context.(make_ccx (empty_master_cx ())) in
    let (cx, _) =
      Nel.map
        (fun file ->
          let docblock = Parsing_heaps.Mutator_reader.get_docblock_unsafe ~reader file in
          let metadata = Context.docblock_overrides docblock metadata in
          let lint_severities = Merge_js.get_lint_severities metadata strict_mode lint_severities in
          let aloc_table = lazy (Parsing_heaps.Mutator_reader.get_aloc_table_unsafe ~reader file) in
          let module_ref = Reason.OrdinaryName (Files.module_ref file) in
          let cx = Context.make ccx metadata file aloc_table module_ref Context.Merging in
          let (_, { Flow_ast.Program.all_comments = comments; _ }) =
            Parsing_heaps.Mutator_reader.get_ast_unsafe ~reader file
          in
          Type_inference_js.scan_for_suppressions cx lint_severities comments;
          cx)
        component
    in
    let suppressions = Context.error_suppressions cx in
    let diff =
      Context_heaps.Merge_context_mutator.add_merge_on_diff worker_mutator component hash
    in
    let duration = Unix.gettimeofday () -. start_time in
    (diff, Ok (Some (suppressions, duration)))

let mk_check_file options ~reader () =
  let get_ast_unsafe file =
    let ((_, { Flow_ast.Program.all_comments; _ }) as ast) =
      Parsing_heaps.Mutator_reader.get_ast_unsafe ~reader file
    in
    let aloc_ast = Ast_loc_utils.loc_to_aloc_mapper#program ast in
    (all_comments, aloc_ast)
  in
  let get_tolerable_file_sig_unsafe file =
    Parsing_heaps.Mutator_reader.get_tolerable_file_sig_unsafe ~reader file |> File_sig.abstractify
  in
  let get_type_sig_unsafe file = Parsing_heaps.Mutator_reader.get_type_sig_unsafe ~reader file in
  let get_aloc_table_unsafe = Parsing_heaps.Mutator_reader.get_aloc_table_unsafe ~reader in
  let get_docblock_unsafe = Parsing_heaps.Mutator_reader.get_docblock_unsafe ~reader in
  let check_file =
    let reader = Abstract_state_reader.Mutator_state_reader reader in
    let cache = Check_cache.create ~capacity:1000 in
    Check_service.mk_check_file ~options ~reader ~cache ()
  in
  fun file ->
    let start_time = Unix.gettimeofday () in
    let info = Module_heaps.Mutator_reader.get_info_unsafe ~reader ~audit:Expensive.ok file in
    if info.Module_heaps.checked then
      let (comments, ast) = get_ast_unsafe file in
      let type_sig = get_type_sig_unsafe file in
      let (file_sig, tolerable_errors) = get_tolerable_file_sig_unsafe file in
      let docblock = get_docblock_unsafe file in
      let aloc_table = lazy (get_aloc_table_unsafe file) in
      let requires =
        let require_loc_map = File_sig.With_ALoc.(require_loc_map file_sig.module_sig) in
        let { Module_heaps.resolved_modules; _ } =
          Module_heaps.Mutator_reader.get_resolved_requires_unsafe ~reader ~audit:Expensive.ok file
        in
        let f mref locs acc =
          let provider = SMap.find mref resolved_modules in
          (mref, locs, provider) :: acc
        in
        SMap.fold f require_loc_map []
      in
      let (cx, typed_ast) = check_file file requires ast comments file_sig docblock aloc_table in
      let coverage = Coverage.file_coverage ~full_cx:cx typed_ast in
      let errors = Context.errors cx in
      let suppressions = Context.error_suppressions cx in
      let severity_cover = Context.severity_cover cx in
      let include_suppressions = Context.include_suppressions cx in
      let aloc_tables = Context.aloc_tables cx in
      let (errors, warnings, suppressions) =
        Error_suppressions.filter_lints
          ~include_suppressions
          suppressions
          errors
          aloc_tables
          severity_cover
      in
      (* add tolerable errors after filtering lints since SignatureVerificationFailure is currently
         an unusual lint that should not be suppressed. *)
      let errors =
        tolerable_errors
        |> Inference_utils.set_of_file_sig_tolerable_errors ~source_file:file
        |> Flow_error.ErrorSet.union errors
      in
      let duration = Unix.gettimeofday () -. start_time in
      Some
        ((cx, type_sig, file_sig, typed_ast), (errors, warnings, suppressions, coverage, duration))
    else
      None

(* This cache is used in check_contents_context below. When we check the
 * contents of a file, we create types from the signatures of dependencies.
 *
 * Note that this cache needs to be invaliated when files change. We can use the
 * set of changed files (determined by the merge stream's signature hashing) to
 * invalidate file-by-file when a recheck transaction commits.
 *
 * This cache also needs to be cleared when we compact the shared heap. The
 * values in this cache can contain lazy thunks which close over shared heap
 * addresses. In the event of a compaction, these addresses can become invalid.
 *
 * Any state derived from the values in this cache also needs to be reset in the
 * event of a compaction, which can be done in the SharedMem.on_compact
 * callback. *)
let check_contents_cache = Check_cache.create ~capacity:1000

(* Variation of merge_context where requires may not have already been
   resolved. This is used by commands that make up a context on the fly. *)
let check_contents_context ~reader options file ast docblock file_sig =
  let (_, { Flow_ast.Program.all_comments = comments; _ }) = ast in
  let ast = Ast_loc_utils.loc_to_aloc_mapper#program ast in
  let file_sig = File_sig.abstractify_locs file_sig in
  (* Loading an aloc_table is unusual for check contents! During check, we use
   * this aloc table for two purposes: (1) to compare concrete and keyed alocs
   * which might be equivalent and (2) to create ALoc.id values which always
   * have the same representation for equivalent locations.
   *
   * If this file is in a cycle, an aloc table will exist and we will
   * successfully fetch it for use in cases (1) and (2). However, in the common
   * case of no cycles, an aloc table may not exist yet, which will cause an
   * exception in the (2) case. The (1) case, where a concrete and keyed
   * location are equivalent, will not occur.
   *
   * Catching the exception provides reasonable behavior, but is not the true
   * fix. Instead, if check-contents needs to deal with cycles, the cyclic
   * dependency on `file` should come from the freshly parsed type sig data, not
   * whatever data is in the heap, and the aloc table should also come from the
   * fresh parse. *)
  let aloc_table =
    lazy
      (try Parsing_heaps.Reader.get_aloc_table_unsafe ~reader file with
      | Parsing_heaps_exceptions.ALoc_table_not_found _ -> ALoc.empty_table file)
  in
  let reader = Abstract_state_reader.State_reader reader in
  let required =
    let require_loc_map = File_sig.With_ALoc.(require_loc_map file_sig.module_sig) in
    let node_modules_containers = !Files.node_modules_containers in
    let f mref ((loc, _) as locs) acc =
      let provider =
        Module_js.imported_module ~options ~reader ~node_modules_containers file loc mref
      in
      (mref, locs, provider) :: acc
    in
    SMap.fold f require_loc_map []
  in
  let cache = check_contents_cache in
  let check_file = Check_service.mk_check_file ~options ~reader ~cache () in
  check_file file required ast comments file_sig docblock aloc_table

(* Wrap a potentially slow operation with a timer that fires every interval seconds. When it fires,
 * it calls ~on_timer. When the operation finishes, the timer is cancelled *)
let with_async_logging_timer ~interval ~on_timer ~f =
  let start_time = Unix.gettimeofday () in
  let timer = ref None in
  let cancel_timer () = Base.Option.iter ~f:Timer.cancel_timer !timer in
  let rec run_timer ?(first_run = false) () =
    ( if not first_run then
      let run_time = Unix.gettimeofday () -. start_time in
      on_timer run_time
    );
    timer := Some (Timer.set_timer ~interval ~callback:run_timer)
  in
  (* Timer is unimplemented in Windows. *)
  if not Sys.win32 then run_timer ~first_run:true ();
  let ret =
    try f () with
    | e ->
      cancel_timer ();
      raise e
  in
  cancel_timer ();
  ret

let merge_job ~worker_mutator ~reader ~job ~options merged elements =
  List.fold_left
    (fun merged -> function
      | Merge_stream.Component ((leader, _) as component) ->
        (* A component may have several files: there's always at least one, and
           multiple files indicate a cycle. *)
        let files =
          component |> Nel.to_list |> Base.List.map ~f:File_key.to_string |> String.concat "\n\t"
        in
        let merge_timeout = Options.merge_timeout options in
        let interval = Base.Option.value_map ~f:(min 15.0) ~default:15.0 merge_timeout in
        (try
           with_async_logging_timer
             ~interval
             ~on_timer:(fun run_time ->
               Hh_logger.info
                 "[%d] Slow MERGE (%f seconds so far): %s"
                 (Unix.getpid ())
                 run_time
                 files;
               Base.Option.iter merge_timeout ~f:(fun merge_timeout ->
                   if run_time >= merge_timeout then
                     raise (Error_message.EMergeTimeout (run_time, files))
               ))
             ~f:(fun () ->
               let start_time = Unix.gettimeofday () in
               (* prerr_endlinef "[%d] MERGE: %s" (Unix.getpid()) files; *)
               let (diff, result) = job ~worker_mutator ~options ~reader component in
               let merge_time = Unix.gettimeofday () -. start_time in
               if Options.should_profile options then (
                 let length = Nel.length component in
                 let leader = File_key.to_string leader in
                 Flow_server_profile.merge ~length ~merge_time ~leader;
                 if merge_time > 1.0 then
                   Hh_logger.info "[%d] perf: merged %s in %f" (Unix.getpid ()) files merge_time
               );
               (leader, diff, result) :: merged)
         with
        | (SharedMem.Out_of_shared_memory | SharedMem.Heap_full | SharedMem.Hash_table_full) as exc
          ->
          raise exc
        (* A catch all suppression is probably a bad idea... *)
        | unwrapped_exc ->
          let exc = Exception.wrap unwrapped_exc in
          let exn_str = Printf.sprintf "%s: %s" files (Exception.to_string exc) in
          (* Ensure heaps are in a good state before continuing. *)
          let diff =
            Context_heaps.Merge_context_mutator.add_merge_on_exn worker_mutator component
          in

          (* In dev mode, fail hard, but log and continue in prod. *)
          if Build_mode.dev then
            Exception.reraise exc
          else
            prerr_endlinef
              "(%d) merge_job THROWS: [%d] %s\n"
              (Unix.getpid ())
              (Nel.length component)
              exn_str;

          (* An errored component is always changed. *)
          let file_loc = Loc.{ none with source = Some leader } |> ALoc.of_loc in
          (* We can't pattern match on the exception type once it's marshalled
             back to the master process, so we pattern match on it here to create
             an error result. *)
          let result =
            Error
              Error_message.(
                match unwrapped_exc with
                | EDebugThrow loc -> (loc, DebugThrow)
                | EMergeTimeout (s, _) -> (file_loc, MergeTimeout s)
                | _ -> (file_loc, MergeJobException exc)
              )
          in
          (leader, diff, result) :: merged))
    merged
    elements

let merge_runner
    ~job
    ~master_mutator
    ~worker_mutator
    ~reader
    ~options
    ~workers
    ~sig_dependency_graph
    ~component_map
    ~recheck_set =
  let num_workers = Options.max_workers options in
  (* (1) make a map from files to their component leaders
     (2) lift recheck set from files to their component leaders *)
  let (leader_map, recheck_leader_set) =
    FilenameMap.fold
      (fun leader component (leader_map, recheck_leader_set) ->
        let (leader_map, recheck_leader) =
          Nel.fold_left
            (fun (leader_map, recheck_leader) file ->
              ( FilenameMap.add file leader leader_map,
                recheck_leader || FilenameSet.mem file recheck_set
              ))
            (leader_map, false)
            component
        in
        let recheck_leader_set =
          if recheck_leader then
            FilenameSet.add leader recheck_leader_set
          else
            recheck_leader_set
        in
        (leader_map, recheck_leader_set))
      component_map
      (FilenameMap.empty, FilenameSet.empty)
  in
  let start_time = Unix.gettimeofday () in
  let stream =
    Merge_stream.create
      ~num_workers
      ~reader
      ~sig_dependency_graph
      ~leader_map
      ~component_map
      ~recheck_leader_set
  in
  Merge_stream.update_server_status stream;

  (* returns parallel lists of filenames, error sets, and suppression sets *)
  let%lwt ret =
    MultiWorkerLwt.call
      workers
      ~job:(merge_job ~worker_mutator ~reader ~options ~job)
      ~neutral:[]
      ~merge:(Merge_stream.merge ~master_mutator stream)
      ~next:(Merge_stream.next stream)
  in
  let total_files = Merge_stream.total_files stream in
  let skipped_count = Merge_stream.skipped_count stream in
  let sig_new_or_changed = Merge_stream.sig_new_or_changed stream in
  Hh_logger.info "Merge skipped %d of %d modules" skipped_count total_files;
  let elapsed = Unix.gettimeofday () -. start_time in
  if Options.should_profile options then Hh_logger.info "merged in %f" elapsed;
  Lwt.return (ret, { skipped_count; sig_new_or_changed })

let merge = merge_runner ~job:merge_component

let mk_check options ~reader () =
  let check_timeout = Options.merge_timeout options in
  (* TODO: add new option *)
  let interval = Base.Option.value_map ~f:(min 5.0) ~default:5.0 check_timeout in
  let check_file = mk_check_file options ~reader () in
  fun file ->
    let file_str = File_key.to_string file in
    try
      with_async_logging_timer
        ~interval
        ~on_timer:(fun run_time ->
          Hh_logger.info
            "[%d] Slow CHECK (%f seconds so far): %s"
            (Unix.getpid ())
            run_time
            file_str;
          Base.Option.iter check_timeout ~f:(fun check_timeout ->
              if run_time >= check_timeout then
                raise (Error_message.ECheckTimeout (run_time, file_str))
          ))
        ~f:(fun () -> Ok (check_file file))
    with
    | (SharedMem.Out_of_shared_memory | SharedMem.Heap_full | SharedMem.Hash_table_full) as exc ->
      raise exc
    (* A catch all suppression is probably a bad idea... *)
    | unwrapped_exc ->
      let exc = Exception.wrap unwrapped_exc in
      let exn_str = Printf.sprintf "%s: %s" (File_key.to_string file) (Exception.to_string exc) in
      (* In dev mode, fail hard, but log and continue in prod. *)
      if Build_mode.dev then
        Exception.reraise exc
      else
        prerr_endlinef "(%d) check_job THROWS: %s\n" (Unix.getpid ()) exn_str;
      let file_loc = Loc.{ none with source = Some file } |> ALoc.of_loc in
      (* We can't pattern match on the exception type once it's marshalled
         back to the master process, so we pattern match on it here to create
         an error result. *)
      Error
        Error_message.(
          match unwrapped_exc with
          | EDebugThrow loc -> (loc, DebugThrow)
          | ECheckTimeout (s, _) -> (file_loc, CheckTimeout s)
          | _ -> (file_loc, CheckJobException exc)
        )
