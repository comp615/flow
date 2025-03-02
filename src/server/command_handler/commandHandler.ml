(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Base.Result
open ServerEnv
open Utils_js
open Lsp
open Types_js_types

type ephemeral_parallelizable_result = ServerProt.Response.response * Hh_json.json option

type ephemeral_nonparallelizable_result =
  ServerEnv.env * ServerProt.Response.response * Hh_json.json option

type persistent_parallelizable_result = LspProt.response * LspProt.metadata

type persistent_nonparallelizable_result = ServerEnv.env * LspProt.response * LspProt.metadata

type 'a workload = profiling:Profiling_js.running -> env:ServerEnv.env -> 'a Lwt.t

(* Returns the result of calling `type_parse_artifacts`, along with a bool option indicating
 * whether the cache was hit -- None if no cache was available, Some true if it was hit, and Some
 * false if it was missed. *)
let type_parse_artifacts_with_cache
    ~options ~env ~profiling ~type_parse_artifacts_cache file artifacts =
  match type_parse_artifacts_cache with
  | None ->
    let result = Type_contents.type_parse_artifacts ~options ~env ~profiling file artifacts in
    (result, None)
  | Some cache ->
    let lazy_result =
      lazy (Type_contents.type_parse_artifacts ~options ~env ~profiling file artifacts)
    in
    let (result, did_hit) = FilenameCache.with_cache_sync file lazy_result cache in
    (result, Some did_hit)

let add_cache_hit_data_to_json json_props did_hit =
  match did_hit with
  | None ->
    (* This means the cache was not available *)
    json_props
  | Some did_hit -> ("cached", Hh_json.JSON_Bool did_hit) :: json_props

(** Catch exceptions, stringify them, and return Error. Otherwise, return
    the unchanged result of calling `f`.

    Does NOT catch Lwt.Canceled, because that is used as a signal to restart the command.
    TODO: this should be a dedicated exception, but we have to make sure nothing
    swallows it. *)
let try_with f =
  (* NOT try%lwt, even though we catch Lwt.Canceled *)
  try f () with
  | Lwt.Canceled as exn ->
    let exn = Exception.wrap exn in
    Exception.reraise exn
  | exn ->
    let exn = Exception.wrap exn in
    Error (Exception.to_string exn)

let try_with_lwt f =
  try%lwt f () with
  | Lwt.Canceled as exn ->
    let exn = Exception.wrap exn in
    Exception.reraise exn
  | exn ->
    let exn = Exception.wrap exn in
    Lwt.return (Error (Exception.to_string exn))

(** Catch exceptions, stringify them, and return Error. Otherwise, return
    the unchanged result of calling `f`.

    Does NOT catch Lwt.Canceled, because that is used as a signal to restart the command.
    TODO: this should be a dedicated exception, but we have to make sure nothing
    swallows it. *)
let try_with_json : (unit -> ('a, string) result * 'json) -> ('a, string) result * 'json =
 fun f ->
  (* NOT try%lwt, even though we catch Lwt.Canceled *)
  try f () with
  | Lwt.Canceled as exn ->
    let exn = Exception.wrap exn in
    Exception.reraise exn
  | exn ->
    let exn = Exception.wrap exn in
    (Error (Exception.to_string exn), None)

let status_log errors =
  if Errors.ConcreteLocPrintableErrorSet.is_empty errors then
    Hh_logger.info "Status: OK"
  else
    Hh_logger.info "Status: Error";
  flush stdout

let convert_errors ~errors ~warnings ~suppressed_errors =
  if
    Errors.ConcreteLocPrintableErrorSet.is_empty errors
    && Errors.ConcreteLocPrintableErrorSet.is_empty warnings
    && suppressed_errors = []
  then
    ServerProt.Response.NO_ERRORS
  else
    ServerProt.Response.ERRORS { errors; warnings; suppressed_errors }

let json_of_parse_error =
  let int x = Hh_json.JSON_Number (string_of_int x) in
  let position p = Hh_json.JSON_Object [("line", int p.Loc.line); ("column", int p.Loc.column)] in
  let location loc =
    Hh_json.JSON_Object [("start", position loc.Loc.start); ("end", position loc.Loc._end)]
  in
  fun (loc, err) ->
    Hh_json.JSON_Object
      [("loc", location loc); ("message", Hh_json.JSON_String (Parse_error.PP.error err))]

let fold_json_of_parse_errors parse_errors acc =
  match parse_errors with
  | err :: _ ->
    ("parse_error", json_of_parse_error err)
    ::
    ("parse_error_count", Hh_json.JSON_Number (parse_errors |> List.length |> string_of_int)) :: acc
  | [] -> acc

let file_input_of_text_document_identifier ~client t =
  let filename = Flow_lsp_conversions.lsp_DocumentIdentifier_to_flow_path t in
  Persistent_connection.get_file client filename

let file_input_of_text_document_identifier_opt ~client_id t =
  Base.Option.map (Persistent_connection.get_client client_id) ~f:(fun client ->
      file_input_of_text_document_identifier ~client t
  )

let file_input_of_text_document_position ~client t =
  let { Lsp.TextDocumentPositionParams.textDocument; _ } = t in
  file_input_of_text_document_identifier ~client textDocument

let file_input_of_text_document_position_opt ~client_id t =
  Base.Option.map (Persistent_connection.get_client client_id) ~f:(fun client ->
      file_input_of_text_document_position ~client t
  )

let file_key_of_file_input ~options file_input =
  let file_options = Options.file_options options in
  File_input.filename_of_file_input file_input |> Files.filename_from_string ~options:file_options

(* This tries to simulate the logic from elsewhere which determines whether we would report
 * errors for a given file. The criteria are
 *
 * 1) The file must be either implicitly included (be in the same dir structure as .flowconfig)
 *    or explicitly included
 * 2) The file must not be ignored
 * 3) The file path must be a Flow file (e.g foo.js and not foo.php or foo/)
 * 4) The file must either have `// @flow` or all=true must be set in the .flowconfig or CLI
 *)
let check_that_we_care_about_this_file =
  let is_stdin file_path = String.equal file_path "-" in
  let check_file_not_ignored ~file_options ~env ~file_path () =
    if Files.wanted ~options:file_options env.ServerEnv.libs file_path then
      Ok ()
    else
      Error "File is ignored"
  in
  let check_file_included ~options ~file_options ~file_path () =
    let file_is_implicitly_included =
      let root_str = spf "%s%s" (Path.to_string (Options.root options)) Filename.dir_sep in
      String_utils.string_starts_with file_path root_str
    in
    if file_is_implicitly_included then
      Ok ()
    else if Files.is_included file_options file_path then
      Ok ()
    else
      Error "File is not implicitly or explicitly included"
  in
  let check_is_flow_file ~file_options ~file_path () =
    if Files.is_flow_file ~options:file_options file_path then
      Ok ()
    else
      Error "File is not a Flow file"
  in
  let check_flow_pragma ~options ~content ~file_key () =
    if Options.all options then
      Ok ()
    else
      let (_, docblock) =
        Parsing_service_js.(parse_docblock docblock_max_tokens file_key content)
      in
      if Docblock.is_flow docblock then
        Ok ()
      else
        Error "File is missing @flow pragma and `all` is not set to `true`"
  in
  fun ~options ~env ~file_key ~content ->
    let file_path = File_key.to_string file_key in
    if is_stdin file_path then
      (* if we don't know the filename (stdin), assume it's ok *)
      Ok ()
    else
      let file_path = Files.imaginary_realpath file_path in
      let file_options = Options.file_options options in
      Ok ()
      >>= check_file_not_ignored ~file_options ~env ~file_path
      >>= check_file_included ~options ~file_options ~file_path
      >>= check_is_flow_file ~file_options ~file_path
      >>= check_flow_pragma ~options ~content ~file_key

type ide_file_error =
  | Skipped of string
  | Failed of string

let json_props_of_skipped reason =
  let open Hh_json in
  [("skipped", JSON_Bool true); ("skip_reason", JSON_String reason)]

let json_of_skipped reason = Some (Hh_json.JSON_Object (json_props_of_skipped reason))

let of_file_input ~options ~env file_input =
  let file_key = file_key_of_file_input ~options file_input in
  match File_input.content_of_file_input file_input with
  | Error msg -> Error (Failed msg)
  | Ok file_contents ->
    (match check_that_we_care_about_this_file ~options ~env ~file_key ~content:file_contents with
    | Error reason -> Error (Skipped reason)
    | Ok () -> Ok (file_key, file_contents))

let get_status ~profiling ~reader ~options env =
  let lazy_stats = Rechecker.get_lazy_stats ~options env in
  let status_response =
    (* collate errors by origin *)
    let (errors, warnings, suppressed_errors) = ErrorCollator.get ~profiling ~reader ~options env in
    let warnings =
      if Options.should_include_warnings options then
        warnings
      else
        Errors.ConcreteLocPrintableErrorSet.empty
    in
    let suppressed_errors =
      if Options.include_suppressions options then
        suppressed_errors
      else
        []
    in
    (* TODO: check status.directory *)
    status_log errors;
    FlowEventLogger.status_response ~num_errors:(Errors.ConcreteLocPrintableErrorSet.cardinal errors);
    convert_errors ~errors ~warnings ~suppressed_errors
  in
  (status_response, lazy_stats)

let autocomplete ~trigger_character ~reader ~options ~env ~profiling ~input ~cursor ~imports =
  match of_file_input ~options ~env input with
  | Error (Failed e) -> (Error e, None)
  | Error (Skipped reason) ->
    let response = (None, { ServerProt.Response.Completion.items = []; is_incomplete = false }) in
    let extra_data = json_of_skipped reason in
    (Ok response, extra_data)
  | Ok (filename, contents) ->
    let cursor_loc =
      let (line, column) = cursor in
      Loc.cursor (Some filename) line column
    in
    let (contents, broader_context) =
      let (line, column) = cursor in
      AutocompleteService_js.add_autocomplete_token contents line column
    in
    Autocomplete_js.autocomplete_set_hooks ~cursor:cursor_loc;
    let file_artifacts_result =
      let parse_result = Type_contents.parse_contents ~options ~profiling contents filename in
      Type_contents.type_parse_artifacts ~options ~env ~profiling filename parse_result
    in
    Autocomplete_js.autocomplete_unset_hooks ();
    let initial_json_props =
      let open Hh_json in
      [
        ("ac_trigger", JSON_String (Base.Option.value trigger_character ~default:"None"));
        ("broader_context", JSON_String broader_context);
      ]
    in
    (match file_artifacts_result with
    | Error _parse_errors ->
      let err_str = "Couldn't parse file in parse_contents" in
      let json_data_to_log =
        let open Hh_json in
        JSON_Object
          (("errors", JSON_Array [JSON_String err_str])
           ::
           ("result", JSON_String "FAILURE_CHECK_CONTENTS")
           :: ("count", JSON_Number "0") :: initial_json_props
          )
      in
      (Error err_str, Some json_data_to_log)
    | Ok
        ( Parse_artifacts { docblock = info; file_sig; ast; parse_errors; _ },
          Typecheck_artifacts { cx; typed_ast }
        ) ->
      Profiling_js.with_timer profiling ~timer:"GetResults" ~f:(fun () ->
          let open AutocompleteService_js in
          let (token_opt, (ac_type_string, results_res)) =
            autocomplete_get_results
              ~env
              ~options
              ~reader
              ~cx
              ~file_sig
              ~ast
              ~typed_ast
              ~imports
              trigger_character
              cursor_loc
          in
          let json_props_to_log =
            ("ac_type", Hh_json.JSON_String ac_type_string)
            ::
            ("docblock", Docblock.json_of_docblock info)
            ::
            ( "token",
              match token_opt with
              | None -> Hh_json.JSON_Null
              | Some token -> Hh_json.JSON_String token
            )
            :: initial_json_props
          in
          let (response, json_props_to_log) =
            let open Hh_json in
            match results_res with
            | AcResult { result; errors_to_log } ->
              let { ServerProt.Response.Completion.items; is_incomplete = _ } = result in
              let result_string =
                match (items, errors_to_log) with
                | (_, []) -> "SUCCESS"
                | ([], _ :: _) -> "FAILURE"
                | (_ :: _, _ :: _) -> "PARTIAL"
              in
              let at_least_one_result_has_documentation =
                Base.List.exists
                  items
                  ~f:(fun ServerProt.Response.Completion.{ documentation; _ } ->
                    Base.Option.is_some documentation
                )
              in
              ( Ok (token_opt, result),
                ("result", JSON_String result_string)
                ::
                ("count", JSON_Number (items |> List.length |> string_of_int))
                ::
                ("errors", JSON_Array (Base.List.map ~f:(fun s -> JSON_String s) errors_to_log))
                ::
                ("documentation", JSON_Bool at_least_one_result_has_documentation)
                :: json_props_to_log
              )
            | AcEmpty reason ->
              ( Ok (token_opt, { ServerProt.Response.Completion.items = []; is_incomplete = false }),
                ("result", JSON_String "SUCCESS")
                ::
                ("count", JSON_Number "0")
                :: ("empty_reason", JSON_String reason) :: json_props_to_log
              )
            | AcFatalError error ->
              ( Error error,
                ("result", JSON_String "FAILURE")
                :: ("errors", JSON_Array [JSON_String error]) :: json_props_to_log
              )
          in
          let json_props_to_log = fold_json_of_parse_errors parse_errors json_props_to_log in
          (response, Some (Hh_json.JSON_Object json_props_to_log))
      ))

let check_file ~options ~env ~profiling ~force file_input =
  let options = { options with Options.opt_all = Options.all options || force } in
  match of_file_input ~options ~env file_input with
  | Error (Failed _reason)
  | Error (Skipped _reason) ->
    ServerProt.Response.NOT_COVERED
  | Ok (file, content) ->
    let result =
      let ((_, parse_errs) as intermediate_result) =
        Type_contents.parse_contents ~options ~profiling content file
      in
      if not (Flow_error.ErrorSet.is_empty parse_errs) then
        Error parse_errs
      else
        Type_contents.type_parse_artifacts ~options ~env ~profiling file intermediate_result
    in
    let (errors, warnings) =
      Type_contents.printable_errors_of_file_artifacts_result ~options ~env file result
    in
    convert_errors ~errors ~warnings ~suppressed_errors:[]

(* This returns result, json_data_to_log, where json_data_to_log is the json data from
 * getdef_get_result which we end up using *)
let get_def_of_check_result ~options ~reader ~profiling ~check_result (file, line, col) =
  Profiling_js.with_timer profiling ~timer:"GetResult" ~f:(fun () ->
      let loc = Loc.cursor (Some file) line col in
      let (Parse_artifacts { file_sig; parse_errors; _ }, Typecheck_artifacts { cx; typed_ast }) =
        check_result
      in
      let file_sig = File_sig.abstractify_locs file_sig in
      GetDef_js.get_def ~options ~reader ~cx ~file_sig ~typed_ast loc |> fun result ->
      let open GetDef_js.Get_def_result in
      let json_props = fold_json_of_parse_errors parse_errors [] in
      match result with
      | Def loc -> (Ok loc, Some (("result", Hh_json.JSON_String "SUCCESS") :: json_props))
      | Partial (loc, msg) ->
        ( Ok loc,
          Some
            (("result", Hh_json.JSON_String "PARTIAL_FAILURE")
             :: ("error", Hh_json.JSON_String msg) :: json_props
            )
        )
      | Bad_loc -> (Ok Loc.none, Some (("result", Hh_json.JSON_String "BAD_LOC") :: json_props))
      | Def_error msg ->
        ( Error msg,
          Some
            (("result", Hh_json.JSON_String "FAILURE")
             :: ("error", Hh_json.JSON_String msg) :: json_props
            )
        )
  )

type infer_type_input = {
  file_input: File_input.t;
  query_position: Loc.position;
  verbose: Verbose.t option;
  omit_targ_defaults: bool;
  evaluate_type_destructors: bool;
  verbose_normalizer: bool;
  max_depth: int;
}

let infer_type
    ~(options : Options.t)
    ~(reader : Parsing_heaps.Reader.reader)
    ~(env : ServerEnv.env)
    ~(profiling : Profiling_js.running)
    ~type_parse_artifacts_cache
    input : ServerProt.Response.infer_type_response * Hh_json.json option =
  let {
    file_input;
    query_position = { Loc.line; column };
    verbose;
    omit_targ_defaults;
    evaluate_type_destructors;
    max_depth;
    verbose_normalizer;
  } =
    input
  in
  match of_file_input ~options ~env file_input with
  | Error (Failed e) -> (Error e, None)
  | Error (Skipped reason) ->
    let response =
      (* TODO: wow, this is a shady way to return no result! *)
      ServerProt.Response.Infer_type_response
        { loc = Loc.none; ty = None; exact_by_default = true; documentation = None }
    in
    let extra_data = json_of_skipped reason in
    (Ok response, extra_data)
  | Ok (file, content) ->
    let options = { options with Options.opt_verbose = verbose } in
    let (file_artifacts_result, did_hit_cache) =
      let parse_result = Type_contents.parse_contents ~options ~profiling content file in
      type_parse_artifacts_with_cache
        ~options
        ~env
        ~profiling
        ~type_parse_artifacts_cache
        file
        parse_result
    in
    (match file_artifacts_result with
    | Error _parse_errors ->
      let err_str = "Couldn't parse file in parse_artifacts" in
      let json_props = add_cache_hit_data_to_json [] did_hit_cache in
      (Error err_str, Some (Hh_json.JSON_Object json_props))
    | Ok ((Parse_artifacts { file_sig; _ }, Typecheck_artifacts { cx; typed_ast }) as check_result)
      ->
      let ((loc, ty), type_at_pos_json_props) =
        Type_info_service.type_at_pos
          ~cx
          ~file_sig
          ~typed_ast
          ~omit_targ_defaults
          ~evaluate_type_destructors
          ~max_depth
          ~verbose_normalizer
          file
          line
          column
      in
      let (getdef_loc_result, _) =
        try_with_json (fun () ->
            get_def_of_check_result ~options ~reader ~profiling ~check_result (file, line, column)
        )
      in
      let documentation =
        match getdef_loc_result with
        | Error _ -> None
        | Ok getdef_loc ->
          Find_documentation.jsdoc_of_getdef_loc ~current_ast:typed_ast ~reader getdef_loc
          |> Base.Option.bind ~f:Find_documentation.documentation_of_jsdoc
      in
      let json_props =
        ("documentation", Hh_json.JSON_Bool (Base.Option.is_some documentation))
        :: add_cache_hit_data_to_json type_at_pos_json_props did_hit_cache
      in
      let exact_by_default = Options.exact_by_default options in
      let response =
        ServerProt.Response.Infer_type_response { loc; ty; exact_by_default; documentation }
      in
      (Ok response, Some (Hh_json.JSON_Object json_props)))

let insert_type
    ~options
    ~env
    ~profiling
    ~file_input
    ~target
    ~verbose
    ~omit_targ_defaults
    ~location_is_strict
    ~ambiguity_strategy =
  let file_key = file_key_of_file_input ~options file_input in
  let options = { options with Options.opt_verbose = verbose } in
  File_input.content_of_file_input file_input >>= fun file_content ->
  Code_action_service.insert_type
    ~options
    ~env
    ~profiling
    ~file_key
    ~file_content
    ~target
    ~omit_targ_defaults
    ~location_is_strict
    ~ambiguity_strategy

let autofix_exports ~options ~env ~profiling ~input =
  let file_key = file_key_of_file_input ~options input in
  File_input.content_of_file_input input >>= fun file_content ->
  Code_action_service.autofix_exports ~options ~env ~profiling ~file_key ~file_content

let collect_rage ~profiling ~options ~reader ~env ~files =
  let items = [] in
  (* options *)
  let data = Printf.sprintf "lazy_mode=%s\n" (Options.lazy_mode options |> Bool.to_string) in
  let items = ("options", data) :: items in
  (* env: checked files *)
  let data =
    Printf.sprintf
      "%s\n\n%s\n"
      (CheckedSet.debug_counts_to_string env.checked_files)
      (CheckedSet.debug_to_string ~limit:200 env.checked_files)
  in
  let items = ("env.checked_files", data) :: items in
  (* env: dependency graph *)
  let dependency_to_string (file, deps) =
    let file = File_key.to_string file in
    let deps =
      Utils_js.FilenameSet.elements deps
      |> Base.List.map ~f:File_key.to_string
      |> ListUtils.first_upto_n 20 (fun t -> Some (Printf.sprintf " ...%d more" t))
      |> String.concat ","
    in
    file ^ ":" ^ deps ^ "\n"
  in
  let dependencies =
    Dependency_info.implementation_dependency_graph env.ServerEnv.dependency_info
    |> Utils_js.FilenameGraph.to_map
    |> Utils_js.FilenameMap.bindings
    |> Base.List.map ~f:dependency_to_string
    |> ListUtils.first_upto_n 200 (fun t -> Some (Printf.sprintf "[shown 200/%d]\n" t))
    |> String.concat ""
  in
  let data = "DEPENDENCIES:\n" ^ dependencies in
  let items = ("env.dependencies", data) :: items in
  (* env: errors *)
  let (errors, warnings, _) = ErrorCollator.get ~profiling ~reader ~options env in
  let json =
    Errors.Json_output.json_of_errors_with_context
      ~strip_root:None
      ~stdin_file:None
      ~offset_kind:Offset_utils.Utf8
      ~suppressed_errors:[]
      ~errors
      ~warnings
      ()
  in
  let data = "ERRORS:\n" ^ Hh_json.json_to_multiline json in
  let items = ("env.errors", data) :: items in
  (* Checking if file hashes are up to date *)
  let items =
    Base.Option.value_map files ~default:items ~f:(fun files ->
        let buf = Buffer.create 1024 in
        Printf.bprintf
          buf
          "Does the content on the disk match the most recent version of the file?\n\n";
        List.iter
          (fun file ->
            (* TODO - this isn't exactly right. It could be something else, right? *)
            let file_key = File_key.SourceFile file in
            let file_state =
              if not (FilenameSet.mem file_key env.ServerEnv.files) then
                "FILE NOT PARSED BY FLOW (likely ignored implicitly or explicitly)"
              else
                match Sys_utils.cat_or_failed file with
                | None -> "ERROR! FAILED TO READ"
                | Some content ->
                  if Parsing_service_js.does_content_match_file_hash ~reader file_key content then
                    "OK"
                  else
                    "HASH OUT OF DATE"
            in
            Printf.bprintf buf "%s: %s\n" file file_state)
          files;
        ("file hash check", Buffer.contents buf) :: items
    )
  in
  let items =
    let buf = Buffer.create 127 in
    let log str =
      Buffer.add_string buf str;
      Buffer.add_char buf '\n'
    in
    LoggingUtils.dump_server_options ~server_options:options ~log;
    ("server_options", Buffer.contents buf) :: items
  in
  items

let dump_types ~options ~env ~profiling ~evaluate_type_destructors file_input =
  let open Base.Result in
  let file = file_key_of_file_input ~options file_input in
  File_input.content_of_file_input file_input >>= fun content ->
  let file_artifacts_result =
    let parse_result = Type_contents.parse_contents ~options ~profiling content file in
    Type_contents.type_parse_artifacts ~options ~env ~profiling file parse_result
  in
  match file_artifacts_result with
  | Error _parse_errors -> Error "Couldn't parse file in parse_contents"
  | Ok (Parse_artifacts { file_sig; _ }, Typecheck_artifacts { cx; typed_ast }) ->
    Ok (Type_info_service.dump_types ~evaluate_type_destructors cx file_sig typed_ast)

let coverage ~options ~env ~profiling ~type_parse_artifacts_cache ~force ~trust file content =
  if Options.trust_mode options = Options.NoTrust && trust then
    ( Error
        "Coverage cannot be run in trust mode if the server is not in trust mode. \n\nRestart the Flow server with --trust-mode=check' to enable this command.",
      None
    )
  else
    let (file_artifacts_result, did_hit_cache) =
      let parse_result = Type_contents.parse_contents ~options ~profiling content file in
      type_parse_artifacts_with_cache
        ~options
        ~env
        ~profiling
        ~type_parse_artifacts_cache
        file
        parse_result
    in
    let extra_data =
      let json_props = add_cache_hit_data_to_json [] did_hit_cache in
      Hh_json.JSON_Object json_props
    in
    match file_artifacts_result with
    | Ok (_, Typecheck_artifacts { cx; typed_ast }) ->
      let coverage =
        Profiling_js.with_timer profiling ~timer:"Coverage" ~f:(fun () ->
            Type_info_service.coverage ~cx ~typed_ast ~force ~trust file content
        )
      in
      (Ok coverage, Some extra_data)
    | Error _parse_errors -> (Error "Couldn't parse file in parse_contents", Some extra_data)

let batch_coverage ~options ~env ~trust ~batch =
  if Options.trust_mode options = Options.NoTrust && trust then
    Error
      "Batch Coverage cannot be run in trust mode if the server is not in trust mode. \n\nRestart the Flow server with --trust-mode=check' to enable this command."
  else if Options.lazy_mode options then
    Error
      "Batch coverage cannot be run in lazy mode.\n\nRestart the Flow server with '--no-lazy' to enable this command."
  else
    let is_checked key = CheckedSet.mem key env.checked_files in
    let filter key = Base.List.exists ~f:(fun elt -> Files.is_prefix elt key) batch in
    let coverage_map =
      FilenameMap.filter
        (fun key _ -> is_checked key && File_key.to_string key |> filter)
        env.coverage
    in
    let response =
      FilenameMap.fold (fun key coverage -> List.cons (key, coverage)) coverage_map []
    in
    Ok response

let serialize_graph graph =
  (* Convert from map/set to lists for serialization to client. *)
  FilenameMap.fold
    (fun f dep_fs acc ->
      let f = File_key.to_string f in
      let dep_fs = FilenameSet.fold (fun dep_f acc -> File_key.to_string dep_f :: acc) dep_fs [] in
      (f, dep_fs) :: acc)
    graph
    []

let output_dependencies ~env root strip_root types_only outfile =
  let strip_root =
    if strip_root then
      Files.relative_path root
    else
      fun x ->
    x
  in
  let dep_graph =
    if types_only then
      Dependency_info.sig_dependency_graph
    else
      Dependency_info.implementation_dependency_graph
  in
  let graph = serialize_graph (dep_graph env.ServerEnv.dependency_info |> FilenameGraph.to_map) in
  Hh_logger.info "printing dependency graph to %s\n" outfile;
  let%lwt out = Lwt_io.open_file ~mode:Lwt_io.Output outfile in
  let%lwt () = LwtUtils.output_graph out strip_root graph in
  let%lwt () = Lwt_io.close out in
  Lwt.return (Ok ())

let get_cycle ~env fn types_only =
  (* Re-calculate SCC *)
  let parsed = env.ServerEnv.files in
  let dependency_info = env.ServerEnv.dependency_info in
  let dependency_graph =
    if types_only then
      Dependency_info.sig_dependency_graph dependency_info
    else
      Dependency_info.implementation_dependency_graph dependency_info
  in
  Ok
    (let components = Sort_js.topsort ~roots:parsed (FilenameGraph.to_map dependency_graph) in
     (* Get component for target file *)
     let component = List.find (Nel.mem ~equal:File_key.equal fn) components in
     (* Restrict dep graph to only in-cycle files *)
     Nel.fold_left
       (fun acc f ->
         Base.Option.fold (FilenameGraph.find_opt f dependency_graph) ~init:acc ~f:(fun acc deps ->
             let subdeps =
               FilenameSet.filter (fun f -> Nel.mem ~equal:File_key.equal f component) deps
             in
             if FilenameSet.is_empty subdeps then
               acc
             else
               FilenameMap.add f subdeps acc
         ))
       FilenameMap.empty
       component
     |> serialize_graph
    )

let find_module ~options ~reader (moduleref, filename) =
  let file = File_key.SourceFile filename in
  let loc = { Loc.none with Loc.source = Some file } in
  let module_name =
    Module_js.imported_module
      ~options
      ~reader:(Abstract_state_reader.State_reader reader)
      ~node_modules_containers:!Files.node_modules_containers
      file
      (ALoc.of_loc loc)
      moduleref
  in
  Module_heaps.Reader.get_file ~reader ~audit:Expensive.warn module_name

let get_def ~options ~reader ~env ~profiling ~type_parse_artifacts_cache (file_input, line, col) =
  match of_file_input ~options ~env file_input with
  | Error (Failed msg) -> (Error msg, None)
  | Error (Skipped reason) ->
    let json_props = ("result", Hh_json.JSON_String "SKIPPED") :: json_props_of_skipped reason in
    (Ok Loc.none, Some (Hh_json.JSON_Object json_props))
  | Ok (file, content) ->
    let (check_result, did_hit_cache) =
      match
        let parse_result = Type_contents.parse_contents ~options ~profiling content file in
        type_parse_artifacts_with_cache
          ~options
          ~env
          ~profiling
          ~type_parse_artifacts_cache
          file
          parse_result
      with
      | (Ok result, did_hit_cache) -> (Ok result, did_hit_cache)
      | (Error _parse_errors, did_hit_cache) ->
        (Error "Couldn't parse file in parse_contents", did_hit_cache)
    in
    (match check_result with
    | Error msg ->
      let json_props = [("error", Hh_json.JSON_String msg)] in
      let json_props = add_cache_hit_data_to_json json_props did_hit_cache in
      (Error msg, Some (Hh_json.JSON_Object json_props))
    | Ok check_result ->
      let (result, json_props) =
        get_def_of_check_result ~options ~reader ~profiling ~check_result (file, line, col)
      in
      let json =
        let json_props = Base.Option.value ~default:[] json_props in
        let json_props = add_cache_hit_data_to_json json_props did_hit_cache in
        Hh_json.JSON_Object json_props
      in
      (result, Some json))

let module_name_of_string ~options module_name_str =
  let file_options = Options.file_options options in
  let path = Path.to_string (Path.make module_name_str) in
  if Files.is_flow_file ~options:file_options path then
    Modulename.Filename (File_key.SourceFile path)
  else
    Modulename.String module_name_str

let get_imports ~options ~reader module_names =
  let add_to_results (map, non_flow) module_name_str =
    let module_name = module_name_of_string ~options module_name_str in
    match Module_heaps.Reader.get_file ~reader ~audit:Expensive.warn module_name with
    | Some file ->
      (* We do not process all modules which are stored in our module
       * database. In case we do not process a module its requirements
       * are not kept track of. To avoid confusing results we notify the
       * client that these modules have not been processed.
       *)
      let { Module_heaps.checked; _ } =
        Module_heaps.Reader.get_info_unsafe ~reader ~audit:Expensive.warn file
      in
      if checked then
        let { Module_heaps.resolved_modules; _ } =
          Module_heaps.Reader.get_resolved_requires_unsafe ~reader ~audit:Expensive.warn file
        in
        let fsig = Parsing_heaps.Reader.get_file_sig_unsafe ~reader file in
        let requires = File_sig.With_Loc.(require_loc_map fsig.module_sig) in
        let mlocs =
          SMap.fold
            (fun mref locs acc ->
              let m = SMap.find mref resolved_modules in
              Modulename.Map.add m locs acc)
            requires
            Modulename.Map.empty
        in
        (SMap.add module_name_str mlocs map, non_flow)
      else
        (map, SSet.add module_name_str non_flow)
    | None ->
      (* We simply ignore non existent modules *)
      (map, non_flow)
  in
  (* Our result is a tuple. The first element is a map from module names to
   * modules imported by them and their locations of import. The second
   * element is a set of modules which are not marked for processing by
   * flow. *)
  List.fold_left add_to_results (SMap.empty, SSet.empty) module_names

let save_state ~saved_state_filename ~genv ~env ~profiling =
  let%lwt () = Saved_state.save ~saved_state_filename ~genv ~env ~profiling in
  Lwt.return (Ok ())

let handle_autocomplete ~trigger_character ~reader ~options ~profiling ~env ~input ~cursor ~imports
    =
  let (result, json_data) =
    try_with_json (fun () ->
        autocomplete ~trigger_character ~reader ~options ~env ~profiling ~input ~cursor ~imports
    )
  in
  let result = Base.Result.map result ~f:snd in
  Lwt.return (ServerProt.Response.AUTOCOMPLETE result, json_data)

let handle_autofix_exports ~options ~input ~profiling ~env =
  let result = try_with (fun () -> autofix_exports ~options ~env ~profiling ~input) in
  Lwt.return (ServerProt.Response.AUTOFIX_EXPORTS result, None)

let handle_check_file ~options ~force ~input ~profiling ~env =
  let response = check_file ~options ~env ~force ~profiling input in
  Lwt.return (ServerProt.Response.CHECK_FILE response, None)

let handle_coverage ~options ~force ~input ~trust ~profiling ~env =
  let (response, json_data) =
    try_with_json (fun () ->
        let options = { options with Options.opt_all = options.Options.opt_all || force } in
        match of_file_input ~options ~env input with
        | Error (Failed msg) -> (Error msg, None)
        | Error (Skipped reason) -> (Error reason, json_of_skipped reason)
        | Ok (file_key, file_contents) ->
          coverage
            ~options
            ~env
            ~profiling
            ~type_parse_artifacts_cache:None
            ~force
            ~trust
            file_key
            file_contents
    )
  in
  Lwt.return (ServerProt.Response.COVERAGE response, json_data)

let handle_batch_coverage ~options ~profiling:_ ~env ~batch ~trust =
  let response = batch_coverage ~options ~env ~batch ~trust in
  Lwt.return (ServerProt.Response.BATCH_COVERAGE response, None)

let handle_cycle ~fn ~types_only ~profiling:_ ~env =
  let response = get_cycle ~env fn types_only in
  Lwt.return (env, ServerProt.Response.CYCLE response, None)

let handle_dump_types ~options ~input ~evaluate_type_destructors ~profiling ~env =
  let response =
    try_with (fun () -> dump_types ~options ~env ~profiling ~evaluate_type_destructors input)
  in
  Lwt.return (ServerProt.Response.DUMP_TYPES response, None)

let handle_find_module ~options ~reader ~moduleref ~filename ~profiling:_ ~env:_ =
  let response = find_module ~options ~reader (moduleref, filename) in
  Lwt.return (ServerProt.Response.FIND_MODULE response, None)

let handle_force_recheck ~files ~focus ~profiling:_ =
  let fileset = SSet.of_list files in
  let reason =
    match files with
    | [filename] -> LspProt.Single_file_changed { filename }
    | _ -> LspProt.Many_files_changed { file_count = List.length files }
  in
  (* `flow force-recheck --focus a.js` not only marks a.js as a focused file, but it also
   * tells Flow that `a.js` has changed. In that case we push a.js to be rechecked and to be
   * focused *)
  if focus then
    ServerMonitorListenerState.push_files_to_force_focused_and_recheck ~reason fileset
  else
    ServerMonitorListenerState.push_files_to_recheck ?metadata:None ~reason fileset;
  (ServerProt.Response.FORCE_RECHECK, None)

let handle_get_def ~reader ~options ~filename ~line ~char ~profiling ~env =
  let (result, json_data) =
    try_with_json (fun () ->
        get_def
          ~reader
          ~options
          ~env
          ~profiling
          ~type_parse_artifacts_cache:None
          (filename, line, char)
    )
  in
  Lwt.return (ServerProt.Response.GET_DEF result, json_data)

let handle_get_imports ~options ~reader ~module_names ~profiling:_ ~env:_ =
  let response = get_imports ~options ~reader module_names in
  Lwt.return (ServerProt.Response.GET_IMPORTS response, None)

let handle_graph_dep_graph ~root ~strip_root ~outfile ~types_only ~profiling:_ ~env =
  let%lwt response = output_dependencies ~env root strip_root types_only outfile in
  Lwt.return (env, ServerProt.Response.GRAPH_DEP_GRAPH response, None)

let handle_infer_type
    ~options
    ~reader
    ~input
    ~line
    ~char
    ~verbose
    ~omit_targ_defaults
    ~evaluate_type_destructors
    ~max_depth
    ~verbose_normalizer
    ~profiling
    ~env =
  let input =
    {
      file_input = input;
      query_position = { Loc.line; column = char };
      verbose;
      omit_targ_defaults;
      evaluate_type_destructors;
      verbose_normalizer;
      max_depth;
    }
  in
  let (result, json_data) =
    try_with_json (fun () ->
        infer_type ~options ~reader ~env ~profiling ~type_parse_artifacts_cache:None input
    )
  in
  Lwt.return (ServerProt.Response.INFER_TYPE result, json_data)

let handle_insert_type
    ~options
    ~file_input
    ~target
    ~verbose
    ~omit_targ_defaults
    ~location_is_strict
    ~ambiguity_strategy
    ~profiling
    ~env =
  let result =
    try_with (fun _ ->
        insert_type
          ~options
          ~env
          ~profiling
          ~file_input
          ~target
          ~verbose
          ~omit_targ_defaults
          ~location_is_strict
          ~ambiguity_strategy
    )
  in
  Lwt.return (ServerProt.Response.INSERT_TYPE result, None)

let handle_rage ~reader ~options ~files ~profiling ~env =
  let items = collect_rage ~profiling ~options ~reader ~env ~files:(Some files) in
  Lwt.return (ServerProt.Response.RAGE items, None)

let handle_status ~reader ~options ~profiling ~env =
  let (status_response, lazy_stats) = get_status ~profiling ~reader ~options env in
  Lwt.return (env, ServerProt.Response.STATUS { status_response; lazy_stats }, None)

let handle_save_state ~saved_state_filename ~genv ~profiling ~env =
  let%lwt result =
    try_with_lwt (fun () -> save_state ~saved_state_filename ~genv ~env ~profiling)
  in
  Lwt.return (env, ServerProt.Response.SAVE_STATE result, None)

let find_code_actions ~reader ~options ~env ~profiling ~params ~client =
  let CodeActionRequest.{ textDocument; range; context = { only; diagnostics } } = params in
  if not (Code_action_service.kind_is_supported ~options only) then
    (* bail out early if we don't support any of the code actions requested *)
    (Ok [], None)
  else
    let file_input = file_input_of_text_document_identifier ~client textDocument in
    match of_file_input ~options ~env file_input with
    | Error (Failed msg) -> (Error msg, None)
    | Error (Skipped reason) ->
      let extra_data = json_of_skipped reason in
      (Ok [], extra_data)
    | Ok (file_key, file_contents) ->
      let (file_artifacts_result, _did_hit_cache) =
        let parse_result =
          Type_contents.parse_contents ~options ~profiling file_contents file_key
        in
        let type_parse_artifacts_cache =
          Some (Persistent_connection.type_parse_artifacts_cache client)
        in
        type_parse_artifacts_with_cache
          ~options
          ~env
          ~profiling
          ~type_parse_artifacts_cache
          file_key
          parse_result
      in
      (match file_artifacts_result with
      | Error _ -> (Ok [], None)
      | Ok
          ( Parse_artifacts { file_sig; tolerable_errors; ast; parse_errors; _ },
            Typecheck_artifacts { cx; typed_ast }
          ) ->
        let uri = TextDocumentIdentifier.(textDocument.uri) in
        let loc = Flow_lsp_conversions.lsp_range_to_flow_loc ~source:file_key range in
        let lsp_init_params = Persistent_connection.lsp_initialize_params client in
        let code_actions =
          Code_action_service.code_actions_at_loc
            ~options
            ~lsp_init_params
            ~env
            ~reader
            ~cx
            ~file_sig
            ~tolerable_errors
            ~ast
            ~typed_ast
            ~parse_errors
            ~diagnostics
            ~only
            ~uri
            ~loc
        in
        let extra_data =
          match code_actions with
          | Error _ -> None
          | Ok code_actions ->
            let open Hh_json in
            let json_of_code_action = function
              | CodeAction.Command Command.{ title; command = _; arguments = _ }
              | CodeAction.Action CodeAction.{ title; kind = _; diagnostics = _; action = _ } ->
                JSON_String title
            in
            let actions = JSON_Array (Base.List.map ~f:json_of_code_action code_actions) in
            Some (JSON_Object [("actions", actions)])
        in
        (code_actions, extra_data))

let add_missing_imports ~reader ~options ~env ~profiling ~client textDocument =
  let file_input = file_input_of_text_document_identifier ~client textDocument in
  let file_key = file_key_of_file_input ~options file_input in
  match File_input.content_of_file_input file_input with
  | Error msg -> Lwt.return (Error msg)
  | Ok file_contents ->
    let type_parse_artifacts_cache =
      Some (Persistent_connection.type_parse_artifacts_cache client)
    in
    let uri = TextDocumentIdentifier.(textDocument.uri) in
    let (file_artifacts_result, _did_hit_cache) =
      let parse_result = Type_contents.parse_contents ~options ~profiling file_contents file_key in
      type_parse_artifacts_with_cache
        ~options
        ~env
        ~profiling
        ~type_parse_artifacts_cache
        file_key
        parse_result
    in
    (match file_artifacts_result with
    | Error _ -> Lwt.return (Ok [])
    | Ok (Parse_artifacts { ast; _ }, Typecheck_artifacts { cx; typed_ast = _ }) ->
      Lwt.return (Ok (Code_action_service.autofix_imports ~options ~env ~reader ~cx ~ast ~uri)))

let organize_imports ~options ~profiling ~client textDocument =
  let file_input = file_input_of_text_document_identifier ~client textDocument in
  let file_key = file_key_of_file_input ~options file_input in
  match File_input.content_of_file_input file_input with
  | Error msg -> Error msg
  | Ok file_contents ->
    let (parse_artifacts, _parse_errors) =
      Type_contents.parse_contents ~options ~profiling file_contents file_key
    in
    (match parse_artifacts with
    | None -> Ok []
    | Some (Parse_artifacts { ast; _ }) -> Ok (Code_action_service.organize_imports ~options ~ast))

type command_handler =
  | Handle_immediately of (profiling:Profiling_js.running -> ephemeral_parallelizable_result)
      (** A command can be handled immediately if it is super duper fast and doesn't require the env.
          These commands will be handled as soon as we read them off the pipe. Almost nothing should ever
          be handled immediately *)
  | Handle_parallelizable of ephemeral_parallelizable_result workload
      (** A command is parallelizable if it passes four conditions
          1. It is fast. Running it in parallel will block the current recheck, so it needs to be really
             fast.
          2. It doesn't use the workers. Currently we can't deal with the recheck using the workers at the
             same time as a command using the workers
          3. It doesn't return a new env. It really should be just a read-only job
          4. It doesn't mind using slightly out of date data. During a recheck, it will be reading the
            oldified data *)
  | Handle_nonparallelizable of ephemeral_nonparallelizable_result workload
      (** A command is nonparallelizable if it can't be handled immediately or parallelized. *)

(* This command is parallelizable, but we will treat it as nonparallelizable if we've been told
 * to wait_for_recheck by the .flowconfig or CLI *)
let mk_parallelizable ~wait_for_recheck ~options f =
  let wait_for_recheck =
    Base.Option.value wait_for_recheck ~default:(Options.wait_for_recheck options)
  in
  if wait_for_recheck then
    Handle_nonparallelizable
      (fun ~profiling ~env ->
        let%lwt (response, json_data) = f ~profiling ~env in
        Lwt.return (env, response, json_data))
  else
    Handle_parallelizable f

(* This function is called as soon as we read an ephemeral command from the pipe. It decides whether
 * the command should be handled immediately or deferred as parallelizable or nonparallelizable.
 * This function does NOT run any handling code itself. *)
let get_ephemeral_handler genv command =
  let options = genv.options in
  let reader = State_reader.create () in
  match command with
  | ServerProt.Request.AUTOCOMPLETE { input; cursor; trigger_character; wait_for_recheck; imports }
    ->
    mk_parallelizable
      ~wait_for_recheck
      ~options
      (handle_autocomplete ~trigger_character ~reader ~options ~input ~cursor ~imports)
  | ServerProt.Request.AUTOFIX_EXPORTS { input; verbose; wait_for_recheck } ->
    let options = { options with Options.opt_verbose = verbose } in
    mk_parallelizable ~wait_for_recheck ~options (handle_autofix_exports ~input ~options)
  | ServerProt.Request.CHECK_FILE { input; verbose; force; include_warnings; wait_for_recheck } ->
    let options =
      {
        options with
        Options.opt_verbose = verbose;
        opt_include_warnings = options.Options.opt_include_warnings || include_warnings;
      }
    in
    mk_parallelizable ~wait_for_recheck ~options (handle_check_file ~options ~force ~input)
  | ServerProt.Request.COVERAGE { input; force; wait_for_recheck; trust } ->
    mk_parallelizable ~wait_for_recheck ~options (handle_coverage ~options ~force ~trust ~input)
  | ServerProt.Request.BATCH_COVERAGE { batch; wait_for_recheck; trust } ->
    mk_parallelizable ~wait_for_recheck ~options (handle_batch_coverage ~options ~trust ~batch)
  | ServerProt.Request.CYCLE { filename; types_only } ->
    (* The user preference is to make this wait for up-to-date data *)
    let file_options = Options.file_options options in
    let fn = Files.filename_from_string ~options:file_options filename in
    Handle_nonparallelizable (handle_cycle ~fn ~types_only)
  | ServerProt.Request.DUMP_TYPES { input; evaluate_type_destructors; wait_for_recheck } ->
    mk_parallelizable
      ~wait_for_recheck
      ~options
      (handle_dump_types ~options ~input ~evaluate_type_destructors)
  | ServerProt.Request.FIND_MODULE { moduleref; filename; wait_for_recheck } ->
    mk_parallelizable
      ~wait_for_recheck
      ~options
      (handle_find_module ~options ~reader ~moduleref ~filename)
  | ServerProt.Request.FORCE_RECHECK { files; focus } ->
    Handle_immediately (handle_force_recheck ~files ~focus)
  | ServerProt.Request.GET_DEF { filename; line; char; wait_for_recheck } ->
    mk_parallelizable
      ~wait_for_recheck
      ~options
      (handle_get_def ~reader ~options ~filename ~line ~char)
  | ServerProt.Request.GET_IMPORTS { module_names; wait_for_recheck } ->
    mk_parallelizable ~wait_for_recheck ~options (handle_get_imports ~options ~reader ~module_names)
  | ServerProt.Request.GRAPH_DEP_GRAPH { root; strip_root; outfile; types_only } ->
    (* The user preference is to make this wait for up-to-date data *)
    Handle_nonparallelizable (handle_graph_dep_graph ~root ~strip_root ~types_only ~outfile)
  | ServerProt.Request.INFER_TYPE
      {
        input;
        line;
        char;
        verbose;
        omit_targ_defaults;
        evaluate_type_destructors;
        wait_for_recheck;
        verbose_normalizer;
        max_depth;
      } ->
    mk_parallelizable
      ~wait_for_recheck
      ~options
      (handle_infer_type
         ~options
         ~reader
         ~input
         ~line
         ~char
         ~verbose
         ~omit_targ_defaults
         ~evaluate_type_destructors
         ~max_depth
         ~verbose_normalizer
      )
  | ServerProt.Request.RAGE { files } ->
    mk_parallelizable ~wait_for_recheck:None ~options (handle_rage ~reader ~options ~files)
  | ServerProt.Request.INSERT_TYPE
      {
        input;
        target;
        wait_for_recheck;
        verbose;
        omit_targ_defaults;
        location_is_strict;
        ambiguity_strategy;
      } ->
    mk_parallelizable
      ~wait_for_recheck
      ~options
      (handle_insert_type
         ~file_input:input
         ~options
         ~target
         ~verbose
         ~omit_targ_defaults
         ~location_is_strict
         ~ambiguity_strategy
      )
  | ServerProt.Request.STATUS { include_warnings } ->
    let options =
      let open Options in
      { options with opt_include_warnings = options.opt_include_warnings || include_warnings }
    in

    (* `flow status` is often used by users to get all the current errors. After talking to some
     * coworkers and users, glevi decided that users would rather that `flow status` always waits
     * for the current recheck to finish. So even though we could technically make `flow status`
     * parallelizable, we choose to make it nonparallelizable *)
    Handle_nonparallelizable (handle_status ~reader ~options)
  | ServerProt.Request.SAVE_STATE { outfile } ->
    (* save-state can take awhile to run. Furthermore, you probably don't want to run this with out
     * of date data. So save-state is not parallelizable *)
    Handle_nonparallelizable (handle_save_state ~saved_state_filename:outfile ~genv)

let send_finished_status_update profiling cmd_str =
  let event =
    ServerStatus.(
      Finishing_up
        { duration = Profiling_js.get_profiling_duration profiling; info = CommandSummary cmd_str }
    )
  in
  MonitorRPC.status_update ~event

let send_ephemeral_response ~profiling ~client_context ~cmd_str ~request_id result =
  send_finished_status_update profiling cmd_str;
  match result with
  | Ok (ret, response, json_data) ->
    FlowEventLogger.ephemeral_command_success ~json_data ~client_context ~profiling;
    MonitorRPC.respond_to_request ~request_id ~response;
    Hh_logger.info "Finished %s" cmd_str;
    Ok ret
  | Error (exn_str, json_data) ->
    FlowEventLogger.ephemeral_command_failure ~client_context ~json_data;
    MonitorRPC.request_failed ~request_id ~exn_str;
    Error ()

let handle_ephemeral_uncaught_exception cmd_str exn =
  let exn_str = Exception.to_string exn in
  let json_data = Some Hh_json.(JSON_Object [("exn", JSON_String exn_str)]) in
  Hh_logger.error ~exn "Uncaught exception while handling a request (%s)" cmd_str;
  Error (exn_str, json_data)

(* This is the common code which wraps each command handler. It deals with stuff like logging and
 * catching exceptions *)
let wrap_ephemeral_handler handler ~genv ~request_id ~client_context ~workload ~cmd_str arg =
  Hh_logger.info "%s" cmd_str;
  MonitorRPC.status_update ~event:ServerStatus.Handling_request_start;

  let should_print_summary = Options.should_profile genv.options in
  let%lwt (profiling, result) =
    Profiling_js.with_profiling_lwt ~label:"Command" ~should_print_summary (fun profiling ->
        try%lwt
          let%lwt result = handler ~genv ~request_id ~workload ~profiling arg in
          Lwt.return (Ok result)
        with
        | Lwt.Canceled as exn -> Exception.(reraise (wrap exn))
        | exn ->
          let exn = Exception.wrap exn in
          Lwt.return (handle_ephemeral_uncaught_exception cmd_str exn)
    )
  in
  Lwt.return (send_ephemeral_response ~profiling ~client_context ~cmd_str ~request_id result)

let wrap_immediate_ephemeral_handler
    handler ~genv ~request_id ~client_context ~workload ~cmd_str arg =
  Hh_logger.info "%s" cmd_str;
  MonitorRPC.status_update ~event:ServerStatus.Handling_request_start;

  let should_print_summary = Options.should_profile genv.options in
  let (profiling, result) =
    Profiling_js.with_profiling_sync ~label:"Command" ~should_print_summary (fun profiling ->
        try Ok (handler ~genv ~request_id ~workload ~profiling arg) with
        | exn ->
          let exn = Exception.wrap exn in
          handle_ephemeral_uncaught_exception cmd_str exn
    )
  in
  send_ephemeral_response ~profiling ~client_context ~cmd_str ~request_id result

(* A few commands need to be handled immediately, as soon as they arrive from the monitor. An
 * `env` is NOT available, since we don't have the server's full attention *)
let handle_ephemeral_immediately_unsafe ~genv:_ ~request_id:_ ~workload ~profiling () =
  let (response, json_data) = workload ~profiling in
  ((), response, json_data)

let handle_ephemeral_immediately =
  wrap_immediate_ephemeral_handler handle_ephemeral_immediately_unsafe

(* If command running in serial (i.e. not in parallel with a recheck) is canceled, it kicks off a
 * recheck itself and then reruns itself
 *
 * While parallelizable commands can be run out of order (some might get deferred),
 * nonparallelizable commands always run in order. So that's why we don't defer commands here.
 *
 * Since this might run a recheck, `workload ~profiling ~env` MUST return the new env.
 *)
let rec run_command_in_serial ~genv ~env ~profiling ~workload =
  try%lwt workload ~profiling ~env with
  | Lwt.Canceled ->
    Hh_logger.info "Command successfully canceled. Running a recheck before restarting the command";
    let%lwt (recheck_profiling, env) = Rechecker.recheck_loop genv env in
    List.iter (fun from -> Profiling_js.merge ~into:profiling ~from) recheck_profiling;
    Hh_logger.info "Now restarting the command";
    run_command_in_serial ~genv ~env ~profiling ~workload

(* A command that is running in parallel with a recheck, if canceled, can't just run a recheck
 * itself. It needs to defer itself until later. *)
let run_command_in_parallel ~env ~profiling ~name ~workload ~mk_workload =
  try%lwt
    let%lwt (response, json_data) = workload ~profiling ~env in
    Lwt.return (response, json_data)
  with
  | Lwt.Canceled as exn ->
    let exn = Exception.wrap exn in
    Hh_logger.info
      "Command successfully canceled. Requeuing the command for after the next recheck.";
    ServerMonitorListenerState.defer_parallelizable_workload ~name (mk_workload ());
    Exception.reraise exn

let rec handle_parallelizable_ephemeral_unsafe
    ~client_context ~cmd_str ~genv ~request_id ~workload ~profiling env =
  let%lwt (response, json_data) =
    let mk_workload () =
      handle_parallelizable_ephemeral ~genv ~request_id ~client_context ~workload ~cmd_str
    in
    run_command_in_parallel ~env ~profiling ~name:cmd_str ~workload ~mk_workload
  in
  Lwt.return ((), response, json_data)

and handle_parallelizable_ephemeral ~genv ~request_id ~client_context ~workload ~cmd_str env =
  try%lwt
    let handler = handle_parallelizable_ephemeral_unsafe ~client_context ~cmd_str in
    let%lwt result =
      wrap_ephemeral_handler handler ~genv ~request_id ~client_context ~workload ~cmd_str env
    in
    match result with
    | Ok ()
    | Error () ->
      Lwt.return_unit
  with
  | Lwt.Canceled ->
    (* It's fine for parallelizable commands to be canceled - they'll be run again later *)
    Lwt.return_unit

let handle_nonparallelizable_ephemeral_unsafe ~genv ~request_id:_ ~workload ~profiling env =
  run_command_in_serial ~genv ~env ~profiling ~workload

let handle_nonparallelizable_ephemeral ~genv ~request_id ~client_context ~workload ~cmd_str env =
  let%lwt result =
    wrap_ephemeral_handler
      handle_nonparallelizable_ephemeral_unsafe
      ~genv
      ~request_id
      ~client_context
      ~workload
      ~cmd_str
      env
  in
  match result with
  | Ok env -> Lwt.return env
  | Error () -> Lwt.return env

let enqueue_or_handle_ephemeral genv (request_id, command_with_context) =
  let { ServerProt.Request.client_logging_context = client_context; command } =
    command_with_context
  in
  let cmd_str = spf "%s: %s" request_id (ServerProt.Request.to_string command) in
  match get_ephemeral_handler genv command with
  | Handle_immediately workload ->
    let result =
      handle_ephemeral_immediately ~genv ~request_id ~client_context ~workload ~cmd_str ()
    in
    (match result with
    | Ok ()
    | Error () ->
      ())
  | Handle_parallelizable workload ->
    let workload =
      handle_parallelizable_ephemeral ~genv ~request_id ~client_context ~workload ~cmd_str
    in
    ServerMonitorListenerState.push_new_parallelizable_workload ~name:cmd_str workload
  | Handle_nonparallelizable workload ->
    let workload =
      handle_nonparallelizable_ephemeral ~genv ~request_id ~client_context ~workload ~cmd_str
    in
    ServerMonitorListenerState.push_new_workload ~name:cmd_str workload

let did_open ~profiling ~reader genv env client (_files : (string * string) Nel.t) :
    ServerEnv.env Lwt.t =
  let options = genv.ServerEnv.options in
  let (errors, warnings, _) =
    ErrorCollator.get_with_separate_warnings ~profiling ~reader ~options env
  in
  Persistent_connection.send_errors_if_subscribed
    ~client
    ~errors_reason:LspProt.Env_change
    ~errors
    ~warnings;
  Lwt.return env

let did_close ~profiling ~reader genv env client : ServerEnv.env Lwt.t =
  let options = genv.options in
  let (errors, warnings, _) =
    ErrorCollator.get_with_separate_warnings ~profiling ~reader ~options env
  in
  Persistent_connection.send_errors_if_subscribed
    ~client
    ~errors_reason:LspProt.Env_change
    ~errors
    ~warnings;
  Lwt.return env

let with_error ?(stack : Utils.callstack option) ~(reason : string) (metadata : LspProt.metadata) :
    LspProt.metadata =
  let open LspProt in
  let stack =
    match stack with
    | Some stack -> stack
    | None -> Utils.Callstack (Exception.get_current_callstack_string 100)
  in
  let error_info = Some (ExpectedError, reason, stack) in
  { metadata with error_info }

let keyvals_of_json (json : Hh_json.json option) : (string * Hh_json.json) list =
  match json with
  | None -> []
  | Some (Hh_json.JSON_Object keyvals) -> keyvals
  | Some json -> [("json_data", json)]

let with_data ~(extra_data : Hh_json.json option) (metadata : LspProt.metadata) : LspProt.metadata =
  let open LspProt in
  let extra_data = metadata.extra_data @ keyvals_of_json extra_data in
  { metadata with extra_data }

(* This is commonly called by persistent handlers when something goes wrong and we need to return
  * an error response *)
let mk_lsp_error_response ~id ~reason ?stack metadata =
  let metadata = with_error ?stack ~reason metadata in
  let (_, reason, Utils.Callstack stack) = Base.Option.value_exn metadata.LspProt.error_info in
  let message =
    match id with
    | Some id ->
      Hh_logger.error "Error: %s\n%s" reason stack;
      let friendly_message =
        "Flow encountered an unexpected error while handling this request. "
        ^ "See the Flow logs for more details."
      in
      let e = { Error.code = Error.UnknownErrorCode; message = friendly_message; data = None } in
      ResponseMessage (id, ErrorResult (e, stack))
    | None ->
      let text =
        Printf.sprintf "%s [%s]\n%s" reason (Error.show_code Error.UnknownErrorCode) stack
      in
      NotificationMessage
        (TelemetryNotification { LogMessage.type_ = MessageType.ErrorMessage; message = text })
  in
  (LspProt.LspFromServer (Some message), metadata)

let handle_persistent_canceled ~id ~metadata ~client:_ ~profiling:_ =
  let e = { Error.code = Error.RequestCancelled; message = "cancelled"; data = None } in
  let response = ResponseMessage (id, ErrorResult (e, "")) in
  let metadata = with_error ~stack:(Utils.Callstack "") ~reason:"cancelled" metadata in
  (LspProt.LspFromServer (Some response), metadata)

let handle_persistent_subscribe ~reader ~options ~metadata ~client ~profiling ~env =
  let (current_errors, current_warnings, _) =
    ErrorCollator.get_with_separate_warnings ~profiling ~reader ~options env
  in
  Persistent_connection.subscribe_client ~client ~current_errors ~current_warnings;
  Lwt.return (env, LspProt.LspFromServer None, metadata)

(* A did_open notification can come in about N files, which is great. But sometimes we'll get
 * N did_open notifications in quick succession. Let's batch them up and run them all at once!
 *)
let (enqueue_did_open_files, handle_persistent_did_open_notification) =
  let pending = ref SMap.empty in
  let enqueue_did_open_files (files : (string * string) Nel.t) =
    (* Overwrite the older content with the newer content *)
    pending := Nel.fold_left (fun acc (fn, content) -> SMap.add fn content acc) !pending files
  in
  let get_and_clear_did_open_files () : (string * string) list =
    let ret = SMap.bindings !pending in
    pending := SMap.empty;
    ret
  in
  let handle_persistent_did_open_notification ~reader ~genv ~metadata ~client ~profiling ~env =
    let%lwt env =
      match get_and_clear_did_open_files () with
      | [] -> Lwt.return env
      | first :: rest -> did_open ~profiling ~reader genv env client (first, rest)
    in
    Lwt.return (env, LspProt.LspFromServer None, metadata)
  in
  (enqueue_did_open_files, handle_persistent_did_open_notification)

let handle_persistent_did_open_notification_no_op ~metadata ~client:_ ~profiling:_ =
  (LspProt.LspFromServer None, metadata)

let handle_persistent_did_change_notification ~params ~metadata ~client ~profiling:_ =
  let { Lsp.DidChange.textDocument; contentChanges } = params in
  let { VersionedTextDocumentIdentifier.uri; version = _ } = textDocument in
  let fn = Lsp_helpers.lsp_uri_to_path uri in
  match Persistent_connection.client_did_change client fn contentChanges with
  | Ok () -> (LspProt.LspFromServer None, metadata)
  | Error (reason, stack) -> mk_lsp_error_response ~id:None ~reason ~stack metadata

let handle_persistent_did_save_notification ~metadata ~client:_ ~profiling:_ =
  (LspProt.LspFromServer None, metadata)

let handle_persistent_did_close_notification ~reader ~genv ~metadata ~client ~profiling ~env =
  let%lwt env = did_close ~profiling ~reader genv env client in
  Lwt.return (env, LspProt.LspFromServer None, metadata)

let handle_persistent_did_close_notification_no_op ~metadata ~client:_ ~profiling:_ =
  (LspProt.LspFromServer None, metadata)

let handle_persistent_cancel_notification ~params ~metadata ~client:_ ~profiling:_ ~env =
  let id = params.CancelRequest.id in
  (* by the time this cancel request shows up in the queue, then it must already *)
  (* have had its effect if any on messages earlier in the queue, and so can be  *)
  (* removed. *)
  ServerMonitorListenerState.(cancellation_requests := IdSet.remove id !cancellation_requests);
  Lwt.return (env, LspProt.LspFromServer None, metadata)

let handle_persistent_did_change_configuration_notification ~params ~metadata ~client ~profiling:_ =
  let open Hh_json_helpers in
  let open Persistent_connection in
  let { Lsp.DidChangeConfiguration.settings } = params in
  let client_config = client_config client in
  let json = Some settings in
  let client_config =
    let suggest = Jget.obj_opt json "suggest" in
    match Jget.bool_opt suggest "autoImports" with
    | Some suggest_autoimports -> { Client_config.suggest_autoimports }
    | None -> client_config
  in
  client_did_change_configuration client client_config;
  (LspProt.LspFromServer None, metadata)

let handle_persistent_get_def
    ~reader ~options ~id ~params ~file_input ~metadata ~client ~profiling ~env =
  let file_input =
    match file_input with
    | Some file_input -> file_input
    | None ->
      (* We must have failed to get the client when we first tried. We could throw here, but this is
       * a little more defensive. The only danger here is that the file contents may have changed *)
      file_input_of_text_document_position ~client params
  in
  let (line, char) = Flow_lsp_conversions.position_of_document_position params in
  let type_parse_artifacts_cache = Some (Persistent_connection.type_parse_artifacts_cache client) in
  let (result, extra_data) =
    get_def ~options ~reader ~env ~profiling ~type_parse_artifacts_cache (file_input, line, char)
  in
  let metadata = with_data ~extra_data metadata in
  match result with
  | Ok loc when loc = Loc.none ->
    let response = ResponseMessage (id, DefinitionResult []) in
    Lwt.return (LspProt.LspFromServer (Some response), metadata)
  | Ok loc ->
    let { TextDocumentPositionParams.textDocument; position = _ } = params in
    let default_uri = textDocument.TextDocumentIdentifier.uri in
    let location = Flow_lsp_conversions.loc_to_lsp_with_default ~default_uri loc in
    let definition_location = { Lsp.DefinitionLocation.location; title = None } in
    let response = ResponseMessage (id, DefinitionResult [definition_location]) in
    Lwt.return (LspProt.LspFromServer (Some response), metadata)
  | Error reason -> Lwt.return (mk_lsp_error_response ~id:(Some id) ~reason metadata)

let handle_persistent_infer_type
    ~options ~reader ~id ~params ~file_input ~metadata ~client ~profiling ~env =
  let open TextDocumentPositionParams in
  let file_input =
    match file_input with
    | Some file_input -> file_input
    | None ->
      (* We must have failed to get the client when we first tried. We could throw here, but this is
       * a little more defensive. The only danger here is that the file contents may have changed *)
      file_input_of_text_document_position ~client params
  in
  let (line, column) = Flow_lsp_conversions.position_of_document_position params in
  (* if Some, would write to server logs *)
  let type_parse_artifacts_cache = Some (Persistent_connection.type_parse_artifacts_cache client) in
  let input =
    {
      file_input;
      query_position = { Loc.line; column };
      verbose = None;
      omit_targ_defaults = false;
      evaluate_type_destructors = false;
      verbose_normalizer = false;
      max_depth = 50;
    }
  in
  let (result, extra_data) =
    infer_type ~options ~reader ~env ~profiling ~type_parse_artifacts_cache input
  in
  let metadata = with_data ~extra_data metadata in
  match result with
  | Ok (ServerProt.Response.Infer_type_response { loc; ty; exact_by_default; documentation }) ->
    (* loc may be the 'none' location; content may be None. *)
    (* If both are none then we'll return null; otherwise we'll return a hover *)
    let default_uri = params.textDocument.TextDocumentIdentifier.uri in
    let location = Flow_lsp_conversions.loc_to_lsp_with_default ~default_uri loc in
    let range =
      if loc = Loc.none then
        None
      else
        Some location.Lsp.Location.range
    in
    let contents =
      match
        Base.List.concat
          [
            Base.Option.to_list ty
            |> List.map (fun elt ->
                   MarkedCode ("flow", Ty_printer.string_of_elt elt ~exact_by_default)
               );
            Base.Option.to_list documentation |> List.map (fun doc -> MarkedString doc);
          ]
      with
      | [] -> [MarkedString "?"]
      | _ :: _ as contents -> contents
    in
    let r =
      match (range, ty) with
      | (None, None) -> None
      | (_, _) -> Some { Lsp.Hover.contents; range }
    in
    let response = ResponseMessage (id, HoverResult r) in
    Lwt.return (LspProt.LspFromServer (Some response), metadata)
  | Error reason -> Lwt.return (mk_lsp_error_response ~id:(Some id) ~reason metadata)

let handle_persistent_code_action_request
    ~reader ~options ~id ~params ~metadata ~client ~profiling ~env =
  let (result, extra_data) = find_code_actions ~reader ~options ~profiling ~env ~client ~params in
  let metadata = with_data ~extra_data metadata in
  match result with
  | Ok code_actions ->
    Lwt.return
      (LspProt.LspFromServer (Some (ResponseMessage (id, CodeActionResult code_actions))), metadata)
  | Error reason -> Lwt.return (mk_lsp_error_response ~id:(Some id) ~reason metadata)

let handle_persistent_autocomplete_lsp
    ~reader ~options ~id ~params ~file_input ~metadata ~client ~profiling ~env =
  let client_config = Persistent_connection.client_config client in
  let lsp_init_params = Persistent_connection.lsp_initialize_params client in
  let is_snippet_supported = Lsp_helpers.supports_snippets lsp_init_params in
  let is_preselect_supported = Lsp_helpers.supports_preselect lsp_init_params in
  let is_label_detail_supported =
    Lsp_helpers.supports_completion_item_label_details lsp_init_params
  in
  let { Completion.loc = lsp_loc; context } = params in
  let file_input =
    match file_input with
    | Some file_input -> file_input
    | None ->
      (* We must have failed to get the client when we first tried. We could throw here, but this is
       * a little more defensive. The only danger here is that the file contents may have changed *)
      file_input_of_text_document_position ~client lsp_loc
  in
  let (line, char) = Flow_lsp_conversions.position_of_document_position lsp_loc in
  let trigger_character =
    Base.Option.value_map
      ~f:(fun completionContext -> completionContext.Completion.triggerCharacter)
      ~default:None
      context
  in
  let imports =
    Persistent_connection.Client_config.suggest_autoimports client_config
    && Options.autoimports options
  in
  let (result, extra_data) =
    autocomplete
      ~trigger_character
      ~reader
      ~options
      ~env
      ~profiling
      ~input:file_input
      ~cursor:(line, char)
      ~imports
  in
  let metadata = with_data ~extra_data metadata in
  match result with
  | Ok (token, completions) ->
    let result =
      Flow_lsp_conversions.flow_completions_to_lsp
        ?token
        ~is_snippet_supported
        ~is_preselect_supported
        ~is_label_detail_supported
        completions
    in
    let response = ResponseMessage (id, CompletionResult result) in
    Lwt.return (LspProt.LspFromServer (Some response), metadata)
  | Error reason -> Lwt.return (mk_lsp_error_response ~id:(Some id) ~reason metadata)

let handle_persistent_signaturehelp_lsp
    ~reader ~options ~id ~params ~file_input ~metadata ~client ~profiling ~env =
  let file_input =
    match file_input with
    | Some file_input -> file_input
    | None ->
      (* We must have failed to get the client when we first tried. We could throw here, but this is
         * a little more defensive. The only danger here is that the file contents may have changed *)
      file_input_of_text_document_position ~client params.SignatureHelp.loc
  in
  let (line, col) = Flow_lsp_conversions.position_of_document_position params.SignatureHelp.loc in
  let fn_content =
    match file_input with
    | File_input.FileContent (fn, content) -> Ok (fn, content)
    | File_input.FileName fn ->
      (try Ok (Some fn, Sys_utils.cat fn) with
      | e ->
        let e = Exception.wrap e in
        Error (Exception.get_ctor_string e, Utils.Callstack (Exception.get_backtrace_string e)))
  in
  match fn_content with
  | Error (reason, stack) -> Lwt.return (mk_lsp_error_response ~id:(Some id) ~reason ~stack metadata)
  | Ok (filename, contents) ->
    let path =
      match filename with
      | Some filename -> filename
      | None -> "-"
    in
    let path = File_key.SourceFile path in
    let (file_artifacts_result, did_hit_cache) =
      let parse_result = Type_contents.parse_contents ~options ~profiling contents path in
      let type_parse_artifacts_cache =
        Some (Persistent_connection.type_parse_artifacts_cache client)
      in
      type_parse_artifacts_with_cache
        ~options
        ~env
        ~profiling
        ~type_parse_artifacts_cache
        path
        parse_result
    in
    let metadata =
      let json_props = add_cache_hit_data_to_json [] did_hit_cache in
      let json = Hh_json.JSON_Object json_props in
      with_data ~extra_data:(Some json) metadata
    in
    (match file_artifacts_result with
    | Error _parse_errors ->
      Lwt.return
        (mk_lsp_error_response
           ~id:(Some id)
           ~reason:"Couldn't parse file in parse_artifacts"
           metadata
        )
    | Ok (Parse_artifacts { file_sig; _ }, Typecheck_artifacts { cx; typed_ast }) ->
      let func_details =
        let file_sig = File_sig.abstractify_locs file_sig in
        let cursor_loc = Loc.cursor (Some path) line col in
        Signature_help.find_signatures ~options ~reader ~cx ~file_sig ~typed_ast cursor_loc
      in
      (match func_details with
      | Ok details ->
        let r = SignatureHelpResult (Flow_lsp_conversions.flow_signature_help_to_lsp details) in
        let response = ResponseMessage (id, r) in
        let has_any_documentation =
          match details with
          | None -> false
          | Some (details_list, _) ->
            Base.List.exists
              details_list
              ~f:
                ServerProt.Response.(
                  fun { func_documentation; param_tys; _ } ->
                    Base.Option.is_some func_documentation
                    || Base.List.exists param_tys ~f:(fun { param_documentation; _ } ->
                           Base.Option.is_some param_documentation
                       )
                )
        in
        let extra_data =
          Some (Hh_json.JSON_Object [("documentation", Hh_json.JSON_Bool has_any_documentation)])
        in
        Lwt.return (LspProt.LspFromServer (Some response), with_data ~extra_data metadata)
      | Error _ ->
        Lwt.return (mk_lsp_error_response ~id:(Some id) ~reason:"Failed to normalize type" metadata)))

let handle_persistent_document_highlight
    ~reader ~options ~id ~params ~metadata ~client ~profiling ~env =
  let file_input = file_input_of_text_document_position ~client params in
  let (result, extra_data) =
    match of_file_input ~options ~env file_input with
    | Error (Failed reason) -> (Error reason, None)
    | Error (Skipped reason) -> (Ok [], json_of_skipped reason)
    | Ok (file_key, content) ->
      let (line, col) = Flow_lsp_conversions.position_of_document_position params in
      let local_refs =
        FindRefs_js.find_local_refs ~reader ~options ~env ~profiling ~file_key ~content ~line ~col
      in
      let extra_data =
        Some
          (Hh_json.JSON_Object
             [
               ( "result",
                 Hh_json.JSON_String
                   (match local_refs with
                   | Ok _ -> "SUCCESS"
                   | _ -> "FAILURE")
               );
             ]
          )
      in
      (match local_refs with
      | Ok (Some (_name, refs)) ->
        (* All the locs are implicitly in the same file *)
        let ref_to_highlight (_, loc) =
          {
            DocumentHighlight.range = Flow_lsp_conversions.loc_to_lsp_range loc;
            kind = Some DocumentHighlight.Text;
          }
        in
        (Ok (Base.List.map ~f:ref_to_highlight refs), extra_data)
      | Ok None ->
        (* e.g. if it was requested on a place that's not even an identifier *)
        (Ok [], extra_data)
      | Error _ as err -> (err, extra_data))
  in
  let metadata = with_data ~extra_data metadata in
  match result with
  | Ok result ->
    let r = DocumentHighlightResult result in
    let response = ResponseMessage (id, r) in
    Lwt.return (LspProt.LspFromServer (Some response), metadata)
  | Error reason -> Lwt.return (mk_lsp_error_response ~id:(Some id) ~reason metadata)

let handle_persistent_coverage ~options ~id ~params ~file_input ~metadata ~client ~profiling ~env =
  let textDocument = params.TypeCoverage.textDocument in
  let file_input =
    match file_input with
    | Some file_input -> file_input
    | None ->
      (* We must have failed to get the client when we first tried. We could throw here, but this is
       * a little more defensive. The only danger here is that the file contents may have changed *)
      file_input_of_text_document_identifier ~client textDocument
  in
  match of_file_input ~options ~env file_input with
  | Error (Failed reason) -> Lwt.return (mk_lsp_error_response ~id:(Some id) ~reason metadata)
  | Error (Skipped reason) ->
    let range = { start = { line = 0; character = 0 }; end_ = { line = 1; character = 0 } } in
    let r =
      TypeCoverageResult
        {
          TypeCoverage.coveredPercent = 0;
          uncoveredRanges = [{ TypeCoverage.range; message = None }];
          defaultMessage = "Use @flow to get type coverage for this file";
        }
    in
    let response = ResponseMessage (id, r) in
    let metadata =
      let extra_data = json_of_skipped reason in
      with_data ~extra_data metadata
    in
    Lwt.return (LspProt.LspFromServer (Some response), metadata)
  | Ok (file_key, file_contents) ->
    let (result, extra_data) =
      (* 'true' makes it report "unknown" for all exprs in non-flow files *)
      let force = Options.all options in
      let type_parse_artifacts_cache =
        Some (Persistent_connection.type_parse_artifacts_cache client)
      in
      coverage
        ~options
        ~env
        ~profiling
        ~type_parse_artifacts_cache
        ~force
        ~trust:false
        file_key
        file_contents
    in
    let metadata = with_data ~extra_data metadata in
    (match result with
    | Ok all_locs ->
      (* Figure out the percentages *)
      let accum_coverage (covered, total) (_loc, cov) =
        let covered =
          match cov with
          | Coverage_response.Tainted
          | Coverage_response.Untainted ->
            covered + 1
          | Coverage_response.Uncovered
          | Coverage_response.Empty ->
            covered
        in
        (covered, total + 1)
      in
      let (covered, total) = Base.List.fold all_locs ~init:(0, 0) ~f:accum_coverage in
      let coveredPercent =
        if total = 0 then
          100
        else
          100 * covered / total
      in
      (* Figure out each individual uncovered span *)
      let uncovereds =
        Base.List.filter_map all_locs ~f:(fun (loc, cov) ->
            match cov with
            | Coverage_response.Tainted
            | Coverage_response.Untainted ->
              None
            | Coverage_response.Uncovered
            | Coverage_response.Empty ->
              Some loc
        )
      in
      (* Imagine a tree of uncovered spans based on range inclusion. *)
      (* This sorted list is a pre-order flattening of that tree. *)
      let sorted = Base.List.sort uncovereds ~compare:Loc.compare in
      (* We can use that sorted list to remove any span which contains another, so *)
      (* the user only sees actionable reports of the smallest causes of untypedness. *)
      (* The algorithm: accept a range if its immediate successor isn't contained by it. *)
      let f (candidate, acc) loc =
        if Loc.contains candidate loc then
          (loc, acc)
        else
          (loc, candidate :: acc)
      in
      let singles =
        match sorted with
        | [] -> []
        | first :: _ ->
          let (final_candidate, singles) = Base.List.fold sorted ~init:(first, []) ~f in
          final_candidate :: singles
      in
      (* Convert to LSP *)
      let loc_to_lsp loc =
        { TypeCoverage.range = Flow_lsp_conversions.loc_to_lsp_range loc; message = None }
      in
      let uncoveredRanges = Base.List.map singles ~f:loc_to_lsp in
      (* Send the results! *)
      let r =
        TypeCoverageResult
          {
            TypeCoverage.coveredPercent;
            uncoveredRanges;
            defaultMessage = "Un-type checked code. Consider adding type annotations.";
          }
      in
      let response = ResponseMessage (id, r) in
      Lwt.return (LspProt.LspFromServer (Some response), metadata)
    | Error reason -> Lwt.return (mk_lsp_error_response ~id:(Some id) ~reason metadata))

let handle_persistent_rage ~reader ~genv ~id ~metadata ~client:_ ~profiling ~env =
  let root = Path.to_string genv.ServerEnv.options.Options.opt_root in
  let items =
    collect_rage ~profiling ~options:genv.ServerEnv.options ~reader ~env ~files:None
    |> Base.List.map ~f:(fun (title, data) -> { Lsp.Rage.title = Some (root ^ ":" ^ title); data })
  in
  let response = ResponseMessage (id, RageResult items) in
  Lwt.return (LspProt.LspFromServer (Some response), metadata)

let handle_persistent_log_command ~id ~metadata ~arguments:_ ~client:_ ~profiling:_ =
  (* don't need to do anything, since everything we need to log is already in `metadata` *)
  (LspProt.LspFromServer (Some (ResponseMessage (id, ExecuteCommandResult ()))), metadata)

let send_workspace_edit ~client ~id ~metadata ~on_response ~on_error label edit =
  let req_id =
    let prefix =
      match id with
      | Lsp.NumberId id -> string_of_int id
      | Lsp.StringId id -> id
    in
    Lsp.StringId (spf "%s:applyEdit" prefix)
  in
  let request =
    RequestMessage (req_id, ApplyWorkspaceEditRequest { ApplyWorkspaceEdit.label; edit })
  in
  let handler = ApplyWorkspaceEditHandler on_response in
  Persistent_connection.push_outstanding_handler client req_id (handler, on_error);
  (LspProt.LspFromServer (Some request), metadata)

let handle_persistent_add_missing_imports_command
    ~reader ~options ~id ~metadata ~textDocument ~client ~profiling ~env =
  let%lwt edits = add_missing_imports ~reader ~options ~env ~profiling ~client textDocument in
  match edits with
  | Error reason -> Lwt.return (mk_lsp_error_response ~id:(Some id) ~reason metadata)
  | Ok [] ->
    (* nothing to do, return immediately *)
    Lwt.return
      (LspProt.LspFromServer (Some (ResponseMessage (id, ExecuteCommandResult ()))), metadata)
  | Ok edits ->
    (* send a workspace/applyEdit command to the client. when it replies, we'll reply to the command *)
    let on_response _result () =
      (* respond to original executeCommand *)
      let response = ResponseMessage (id, ExecuteCommandResult ()) in
      Persistent_connection.send_response (LspProt.LspFromServer (Some response), metadata) client
    in
    let on_error _ () = (* TODO send error to client *) () in
    let label = Some "Add missing imports" in
    let uri = TextDocumentIdentifier.(textDocument.uri) in
    let edit = { WorkspaceEdit.changes = Lsp.UriMap.singleton uri edits } in
    Lwt.return (send_workspace_edit ~client ~id ~metadata ~on_response ~on_error label edit)

let handle_persistent_organize_imports_command
    ~options ~id ~metadata ~textDocument ~client ~profiling =
  match organize_imports ~options ~profiling ~client textDocument with
  | Error reason -> mk_lsp_error_response ~id:(Some id) ~reason metadata
  | Ok [] ->
    (* nothing to do, return immediately *)
    (LspProt.LspFromServer (Some (ResponseMessage (id, ExecuteCommandResult ()))), metadata)
  | Ok edits ->
    (* send a workspace/applyEdit command to the client. when it replies, we'll reply to the command *)
    let on_response _result () =
      (* respond to original executeCommand *)
      let response = ResponseMessage (id, ExecuteCommandResult ()) in
      Persistent_connection.send_response (LspProt.LspFromServer (Some response), metadata) client
    in
    let on_error _ () = (* TODO send error to client *) () in
    let label = Some "Organize imports" in
    let uri = TextDocumentIdentifier.(textDocument.uri) in
    let edit = { WorkspaceEdit.changes = Lsp.UriMap.singleton uri edits } in
    send_workspace_edit ~client ~id ~metadata ~on_response ~on_error label edit

let handle_persistent_malformed_command ~id ~metadata ~client:_ ~profiling:_ =
  mk_lsp_error_response ~id:(Some id) ~reason:"Malformed command" metadata

let handle_persistent_unsupported ?id ~unhandled ~metadata ~client:_ ~profiling:_ () =
  let message = Printf.sprintf "Unhandled method %s" (Lsp_fmt.message_name_to_string unhandled) in
  let response =
    match id with
    | Some id ->
      let e = { Error.code = Error.MethodNotFound; message; data = None } in
      ResponseMessage (id, ErrorResult (e, ""))
    | None ->
      NotificationMessage
        (TelemetryNotification { LogMessage.type_ = MessageType.ErrorMessage; message })
  in
  (LspProt.LspFromServer (Some response), metadata)

let handle_result_from_client ~id ~metadata ~(result : Lsp.lsp_result) ~client ~profiling:_ =
  (match Persistent_connection.pop_outstanding_handler client id with
  | Some (handler, handle_error) ->
    (match (result, handler) with
    | (ApplyWorkspaceEditResult result, ApplyWorkspaceEditHandler handle) -> handle result ()
    | (ErrorResult (e, msg), _) -> handle_error (e, msg) ()
    | _ -> ())
  | None -> ());
  (LspProt.LspFromServer None, metadata)

(* What should we do if we get multiple requests for the same URI? Each request wants the most
 * up-to-date live errors, so if we have 10 pending requests then we would want to send the same
 * response to each. And we could do that, but it might have some weird side effects:
 *
 * 1. Logging would make this look faster than it is, since we're doing a single check to respond
 *    to N requests
 * 2. The LSP process would have to integrate N responses into its store of errors
 *
 * So instead we just respond that the first N-1 requests were canceled and send a response to the
 * Nth request. Since it's very cheap to cancel a request, this shouldn't delay the LSP process
 * getting a response *)
let handle_live_errors_request =
  (* How do we know that we're responding to the latest request for a URI? Keep track of the
   * latest metadata object *)
  let uri_to_latest_metadata_map = ref SMap.empty in
  let is_latest_metadata uri metadata =
    match SMap.find_opt uri !uri_to_latest_metadata_map with
    | Some latest_metadata -> latest_metadata = metadata
    | None -> false
  in
  fun ~options ~uri ~metadata ->
    (* Immediately store the latest metadata *)
    uri_to_latest_metadata_map := SMap.add uri metadata !uri_to_latest_metadata_map;
    fun ~client ~profiling ~env ->
      if not (is_latest_metadata uri metadata) then
        (* A more recent request for live errors has come in for this file. So let's cancel
         * this one and let the later one handle it *)
        Lwt.return
          ( LspProt.(
              LiveErrorsResponse
                (Error
                   {
                     live_errors_failure_kind = Canceled_error_response;
                     live_errors_failure_reason = "Subsumed by a later request";
                     live_errors_failure_uri = Lsp.DocumentUri.of_string uri;
                   }
                )
            ),
            metadata
          )
      else
        (* This is the most recent live errors request we've received for this file. All the
         * older ones have already been responded to or canceled *)
        let file_path = Lsp_helpers.lsp_uri_to_path (Lsp.DocumentUri.of_string uri) in
        let%lwt ret =
          let file_input = Persistent_connection.get_file client file_path in
          match file_input with
          | File_input.FileName _ ->
            (* Maybe we've received a didClose for this file? Or maybe we got a request for a file
             * that wasn't open in the first place (that would be a bug). *)
            Lwt.return
              ( LspProt.(
                  LiveErrorsResponse
                    (Error
                       {
                         live_errors_failure_kind = Errored_error_response;
                         live_errors_failure_reason =
                           spf "Cannot get live errors for %s: File not open" file_path;
                         live_errors_failure_uri = Lsp.DocumentUri.of_string uri;
                       }
                    )
                ),
                metadata
              )
          | File_input.FileContent (_, content) ->
            let%lwt (live_errors, live_warnings, metadata) =
              let file_key = file_key_of_file_input ~options file_input in
              match check_that_we_care_about_this_file ~options ~env ~file_key ~content with
              | Ok () ->
                let file_key =
                  let file_options = Options.file_options options in
                  Files.filename_from_string ~options:file_options file_path
                in
                let (result, did_hit_cache) =
                  let ((_, parse_errs) as intermediate_result) =
                    Type_contents.parse_contents ~options ~profiling content file_key
                  in
                  if not (Flow_error.ErrorSet.is_empty parse_errs) then
                    (Error parse_errs, None)
                  else
                    let type_parse_artifacts_cache =
                      Some (Persistent_connection.type_parse_artifacts_cache client)
                    in
                    type_parse_artifacts_with_cache
                      ~options
                      ~env
                      ~profiling
                      ~type_parse_artifacts_cache
                      file_key
                      intermediate_result
                in
                let (live_errors, live_warnings) =
                  Type_contents.printable_errors_of_file_artifacts_result
                    ~options
                    ~env
                    file_key
                    result
                in
                let metadata =
                  let json_props = add_cache_hit_data_to_json [] did_hit_cache in
                  let json = Hh_json.JSON_Object json_props in
                  with_data ~extra_data:(Some json) metadata
                in
                Lwt.return (live_errors, live_warnings, metadata)
              | Error reason ->
                Hh_logger.info "Not reporting live errors for file %S: %s" file_path reason;

                let metadata =
                  let extra_data = json_of_skipped reason in
                  with_data ~extra_data metadata
                in

                (* If the LSP requests errors for a file for which we wouldn't normally emit errors
                 * then just return empty sets *)
                Lwt.return
                  ( Errors.ConcreteLocPrintableErrorSet.empty,
                    Errors.ConcreteLocPrintableErrorSet.empty,
                    metadata
                  )
            in
            let live_errors_uri = Lsp.DocumentUri.of_string uri in
            let live_diagnostics =
              Flow_lsp_conversions.diagnostics_of_flow_errors
                ~errors:live_errors
                ~warnings:live_warnings
              |> Lsp.UriMap.find_opt live_errors_uri
              |> Base.Option.value ~default:[]
            in
            Lwt.return
              ( LspProt.LiveErrorsResponse (Ok { LspProt.live_diagnostics; live_errors_uri }),
                metadata
              )
        in
        (* If we've successfully run and there isn't a more recent request for this URI,
         * then remove the entry from the map *)
        if is_latest_metadata uri metadata then
          uri_to_latest_metadata_map := SMap.remove uri !uri_to_latest_metadata_map;
        Lwt.return ret

type persistent_command_handler =
  | Handle_persistent_immediately of
      (client:Persistent_connection.single_client ->
      profiling:Profiling_js.running ->
      persistent_parallelizable_result
      )
      (** A command can be handled immediately if it is super duper fast and doesn't require the env.
          These commands will be handled as soon as we read them off the pipe. Almost nothing should ever
          be handled immediately *)
  | Handle_parallelizable_persistent of
      (client:Persistent_connection.single_client -> persistent_parallelizable_result workload)
      (** A command is parallelizable if it passes four conditions
          1. It is fast. Running it in parallel will block the current recheck, so it needs to be really
            fast.
          2. It doesn't use the workers. Currently we can't deal with the recheck using the workers at the
            same time as a command using the workers
          3. It doesn't return a new env. It really should be just a read-only job
          4. It doesn't mind using slightly out of date data. During a recheck, it will be reading the
            oldified data *)
  | Handle_nonparallelizable_persistent of
      (client:Persistent_connection.single_client -> persistent_nonparallelizable_result workload)
      (** A command is nonparallelizable if it can't be handled immediately or parallelized. *)

(* This command is parallelizable, but we will treat it as nonparallelizable if we've been told
 * to wait_for_recheck by the .flowconfig *)
let mk_parallelizable_persistent ~options f =
  let wait_for_recheck = Options.wait_for_recheck options in
  if wait_for_recheck then
    Handle_nonparallelizable_persistent
      (fun ~client ~profiling ~env ->
        let%lwt (msg, metadata) = f ~client ~profiling ~env in
        Lwt.return (env, msg, metadata))
  else
    Handle_parallelizable_persistent f

(* get_persistent_handler can do a tiny little bit of work, but it's main job is just returning the
 * persistent command's handler.
 *)
let get_persistent_handler ~genv ~client_id ~request:(request, metadata) :
    persistent_command_handler =
  let open LspProt in
  let options = genv.ServerEnv.options in
  let reader = State_reader.create () in
  match request with
  | LspToServer (RequestMessage (id, _))
    when IdSet.mem id !ServerMonitorListenerState.cancellation_requests ->
    (* We don't do any work, we just immediately tell the monitor that this request was already
       * canceled *)
    Handle_persistent_immediately (handle_persistent_canceled ~id ~metadata)
  | Subscribe ->
    (* This mutates env, so it can't run in parallel *)
    Handle_nonparallelizable_persistent (handle_persistent_subscribe ~reader ~options ~metadata)
  | LspToServer (NotificationMessage (DidOpenNotification params)) ->
    let { Lsp.DidOpen.textDocument } = params in
    let { Lsp.TextDocumentItem.text; uri; languageId = _; version = _ } = textDocument in
    let fn = Lsp_helpers.lsp_uri_to_path uri in
    let files = Nel.one (fn, text) in
    let did_anything_change =
      match Persistent_connection.get_client client_id with
      | None -> false
      | Some client ->
        (* We want to create a local copy of this file immediately, so we can respond to requests
              * about this file *)
        Persistent_connection.client_did_open client ~files
    in
    if did_anything_change then (
      enqueue_did_open_files files;

      (* This mutates env, so it can't run in parallel *)
      Handle_nonparallelizable_persistent
        (handle_persistent_did_open_notification ~reader ~genv ~metadata)
    ) else
      (* It's a no-op, so we can respond immediately *)
      Handle_persistent_immediately (handle_persistent_did_open_notification_no_op ~metadata)
  | LspToServer (NotificationMessage (DidChangeNotification params)) ->
    (* This just updates our copy of the file in question. We want to do this immediately *)
    Handle_persistent_immediately (handle_persistent_did_change_notification ~params ~metadata)
  | LspToServer (NotificationMessage (DidSaveNotification _params)) ->
    (* No-op can be handled immediately *)
    Handle_persistent_immediately (handle_persistent_did_save_notification ~metadata)
  | LspToServer (NotificationMessage (DidCloseNotification params)) ->
    let { Lsp.DidClose.textDocument } = params in
    let fn = Lsp_helpers.lsp_textDocumentIdentifier_to_filename textDocument in
    let filenames = Nel.one fn in
    let did_anything_change =
      match Persistent_connection.get_client client_id with
      | None -> false
      | Some client ->
        (* Close this file immediately in case another didOpen comes soon *)
        Persistent_connection.client_did_close client ~filenames
    in
    if did_anything_change then
      (* This mutates env, so it can't run in parallel *)
      Handle_nonparallelizable_persistent
        (handle_persistent_did_close_notification ~reader ~genv ~metadata)
    else
      (* It's a no-op, so we can respond immediately *)
      Handle_persistent_immediately (handle_persistent_did_close_notification_no_op ~metadata)
  | LspToServer (NotificationMessage (CancelRequestNotification params)) ->
    (* The general idea here is this:
       *
       * 1. As soon as we get a cancel notification, add the ID to the canceled requests set.
       * 2. When a request comes in or runs with the canceled ID, cancel that request and immediately
       *    respond that the request has been canceled.
       * 3. When we go to run a request that has been canceled, skip it's normal handler and instead
       *    respond that the request has been canceled.
       * 4. When the nonparallelizable cancel notification workload finally runs, remove the ID from
       *    the set. We're guaranteed that the canceled request will not show up later *)
    let id = params.CancelRequest.id in
    ServerMonitorListenerState.(cancellation_requests := IdSet.add id !cancellation_requests);
    Handle_nonparallelizable_persistent (handle_persistent_cancel_notification ~params ~metadata)
  | LspToServer (NotificationMessage (DidChangeConfigurationNotification params)) ->
    Handle_persistent_immediately
      (handle_persistent_did_change_configuration_notification ~params ~metadata)
  | LspToServer (RequestMessage (id, DefinitionRequest params)) ->
    (* Grab the file contents immediately in case of any future didChanges *)
    let file_input = file_input_of_text_document_position_opt ~client_id params in
    mk_parallelizable_persistent
      ~options
      (handle_persistent_get_def ~reader ~options ~id ~params ~file_input ~metadata)
  | LspToServer (RequestMessage (id, HoverRequest params)) ->
    (* Grab the file contents immediately in case of any future didChanges *)
    let file_input = file_input_of_text_document_position_opt ~client_id params in
    mk_parallelizable_persistent
      ~options
      (handle_persistent_infer_type ~options ~reader ~id ~params ~file_input ~metadata)
  | LspToServer (RequestMessage (id, CodeActionRequest params)) ->
    mk_parallelizable_persistent
      ~options
      (handle_persistent_code_action_request ~reader ~options ~id ~params ~metadata)
  | LspToServer (RequestMessage (id, CompletionRequest params)) ->
    (* Grab the file contents immediately in case of any future didChanges *)
    let loc = params.Completion.loc in
    let file_input = file_input_of_text_document_position_opt ~client_id loc in
    mk_parallelizable_persistent
      ~options
      (handle_persistent_autocomplete_lsp ~reader ~options ~id ~params ~file_input ~metadata)
  | LspToServer (RequestMessage (id, SignatureHelpRequest params)) ->
    (* Grab the file contents immediately in case of any future didChanges *)
    let loc = params.SignatureHelp.loc in
    let file_input = file_input_of_text_document_position_opt ~client_id loc in
    mk_parallelizable_persistent
      ~options
      (handle_persistent_signaturehelp_lsp ~reader ~options ~id ~params ~file_input ~metadata)
  | LspToServer (RequestMessage (id, DocumentHighlightRequest params)) ->
    mk_parallelizable_persistent
      ~options
      (handle_persistent_document_highlight ~reader ~options ~id ~params ~metadata)
  | LspToServer (RequestMessage (id, TypeCoverageRequest params)) ->
    (* Grab the file contents immediately in case of any future didChanges *)
    let textDocument = params.TypeCoverage.textDocument in
    let file_input = file_input_of_text_document_identifier_opt ~client_id textDocument in
    mk_parallelizable_persistent
      ~options
      (handle_persistent_coverage ~options ~id ~params ~file_input ~metadata)
  | LspToServer (RequestMessage (id, RageRequest)) ->
    (* Whoever is waiting for the rage results probably doesn't want to wait for a recheck *)
    mk_parallelizable_persistent ~options (handle_persistent_rage ~reader ~genv ~id ~metadata)
  | LspToServer (RequestMessage (id, ExecuteCommandRequest params)) ->
    let ExecuteCommand.{ command = Command.Command command; arguments } = params in
    let extra_data =
      let open Hh_json in
      let arguments_json =
        match arguments with
        | None -> JSON_Null
        | Some jsons -> JSON_Array jsons
      in
      Some (JSON_Object [("command", JSON_String command); ("arguments", arguments_json)])
    in
    let metadata = with_data ~extra_data metadata in
    (match command with
    | "log" -> Handle_persistent_immediately (handle_persistent_log_command ~id ~arguments ~metadata)
    | "source.addMissingImports" ->
      (match arguments with
      | Some [json] ->
        let textDocument = Lsp_fmt.parse_textDocumentIdentifier (Some json) in
        mk_parallelizable_persistent
          ~options
          (handle_persistent_add_missing_imports_command
             ~reader
             ~options
             ~id
             ~metadata
             ~textDocument
          )
      | _ -> Handle_persistent_immediately (handle_persistent_malformed_command ~id ~metadata))
    | "source.organizeImports" ->
      (match arguments with
      | Some [json] ->
        let textDocument = Lsp_fmt.parse_textDocumentIdentifier (Some json) in
        Handle_persistent_immediately
          (handle_persistent_organize_imports_command ~options ~id ~metadata ~textDocument)
      | _ -> Handle_persistent_immediately (handle_persistent_malformed_command ~id ~metadata))
    | _ -> Handle_persistent_immediately (handle_persistent_malformed_command ~id ~metadata))
  | LspToServer (ResponseMessage (id, result)) ->
    Handle_persistent_immediately (handle_result_from_client ~id ~result ~metadata)
  | LspToServer unhandled ->
    let id =
      match unhandled with
      | RequestMessage (id, _) -> Some id
      | _ -> None
    in
    (* We can reject unsupported stuff immediately *)
    Handle_persistent_immediately (handle_persistent_unsupported ?id ~unhandled ~metadata ())
  | LiveErrorsRequest uri ->
    let uri = Lsp.DocumentUri.to_string uri in
    (* We can handle live errors even during a recheck *)
    mk_parallelizable_persistent ~options (handle_live_errors_request ~options ~uri ~metadata)

type 'a persistent_handling_result = 'a * LspProt.response * LspProt.metadata

let check_if_cancelled ~profiling ~client request metadata =
  match request with
  | LspProt.LspToServer (RequestMessage (id, _))
    when IdSet.mem id !ServerMonitorListenerState.cancellation_requests ->
    Hh_logger.info "Skipping canceled persistent request: %s" (LspProt.string_of_request request);

    (* We can't actually skip a canceled request...we need to send a response. But we can
     * skip the normal handler *)
    Some (handle_persistent_canceled ~id ~metadata ~client ~profiling)
  | _ -> None

let handle_persistent_uncaught_exception request e =
  let exception_constructor = Exception.get_ctor_string e in
  let stack = Exception.get_backtrace_string e in
  LspProt.UncaughtException { request; exception_constructor; stack }

let send_persistent_response ~profiling ~client request result =
  let server_profiling = Some profiling in
  let server_logging_context = Some (FlowEventLogger.get_context ()) in
  let (ret, lsp_response, metadata) = result in
  let metadata = { metadata with LspProt.server_profiling; server_logging_context } in
  let response = (lsp_response, metadata) in
  Persistent_connection.send_response response client;
  Hh_logger.info "Persistent response: %s" (LspProt.string_of_response lsp_response);
  (* we'll send this "Finishing_up" event only after sending the LSP response *)
  send_finished_status_update profiling (LspProt.string_of_request request);
  ret

let wrap_persistent_handler
    (type a b c)
    (handler :
      genv:ServerEnv.genv ->
      workload:a ->
      client:Persistent_connection.single_client ->
      profiling:Profiling_js.running ->
      b ->
      c persistent_handling_result Lwt.t
      )
    ~(genv : ServerEnv.genv)
    ~(client_id : LspProt.client_id)
    ~(request : LspProt.request_with_metadata)
    ~(workload : a)
    ~(default_ret : c)
    (arg : b) : c Lwt.t =
  let (request, metadata) = request in
  match Persistent_connection.get_client client_id with
  | None ->
    Hh_logger.error "Unknown persistent client %d. Maybe connection went away?" client_id;
    Lwt.return default_ret
  | Some client ->
    Hh_logger.info "Persistent request: %s" (LspProt.string_of_request request);
    MonitorRPC.status_update ~event:ServerStatus.Handling_request_start;

    let should_print_summary = Options.should_profile genv.options in
    let%lwt (profiling, result) =
      Profiling_js.with_profiling_lwt ~label:"Command" ~should_print_summary (fun profiling ->
          match check_if_cancelled ~profiling ~client request metadata with
          | Some (response, json_data) -> Lwt.return (default_ret, response, json_data)
          | None ->
            (try%lwt handler ~genv ~workload ~client ~profiling arg with
            | Lwt.Canceled as e ->
              (* Don't swallow Lwt.Canceled. Parallelizable commands may be canceled and run again
               * later. *)
              Exception.(reraise (wrap e))
            | e ->
              let response = handle_persistent_uncaught_exception request (Exception.wrap e) in
              Lwt.return (default_ret, response, metadata))
      )
    in
    Lwt.return (send_persistent_response ~profiling ~client request result)

let wrap_immediate_persistent_handler
    (type a b c)
    (handler :
      genv:ServerEnv.genv ->
      workload:a ->
      client:Persistent_connection.single_client ->
      profiling:Profiling_js.running ->
      b ->
      c persistent_handling_result
      )
    ~(genv : ServerEnv.genv)
    ~(client_id : LspProt.client_id)
    ~(request : LspProt.request_with_metadata)
    ~(workload : a)
    ~(default_ret : c)
    (arg : b) : c =
  let (request, metadata) = request in
  match Persistent_connection.get_client client_id with
  | None ->
    Hh_logger.error "Unknown persistent client %d. Maybe connection went away?" client_id;
    default_ret
  | Some client ->
    Hh_logger.info "Persistent request: %s" (LspProt.string_of_request request);
    MonitorRPC.status_update ~event:ServerStatus.Handling_request_start;

    let should_print_summary = Options.should_profile genv.options in
    let (profiling, result) =
      Profiling_js.with_profiling_sync ~label:"Command" ~should_print_summary (fun profiling ->
          match check_if_cancelled ~profiling ~client request metadata with
          | Some (response, json_data) -> (default_ret, response, json_data)
          | None ->
            (try handler ~genv ~workload ~client ~profiling arg with
            | e ->
              let response = handle_persistent_uncaught_exception request (Exception.wrap e) in
              (default_ret, response, metadata))
      )
    in
    send_persistent_response ~profiling ~client request result

let handle_persistent_immediately_unsafe ~genv:_ ~workload ~client ~profiling () =
  let (response, json_data) = workload ~client ~profiling in
  ((), response, json_data)

let handle_persistent_immediately ~genv ~client_id ~request ~workload =
  wrap_immediate_persistent_handler
    handle_persistent_immediately_unsafe
    ~genv
    ~client_id
    ~request
    ~workload
    ~default_ret:()
    ()

let rec handle_parallelizable_persistent_unsafe
    ~request ~genv ~name ~workload ~client ~profiling env : unit persistent_handling_result Lwt.t =
  let mk_workload () =
    let client_id = Persistent_connection.get_id client in
    handle_parallelizable_persistent ~genv ~client_id ~request ~name ~workload
  in
  let workload = workload ~client in
  let%lwt (response, json_data) =
    run_command_in_parallel ~env ~profiling ~name ~workload ~mk_workload
  in
  Lwt.return ((), response, json_data)

and handle_parallelizable_persistent ~genv ~client_id ~request ~name ~workload env : unit Lwt.t =
  try%lwt
    wrap_persistent_handler
      (handle_parallelizable_persistent_unsafe ~request ~name)
      ~genv
      ~client_id
      ~request
      ~workload
      ~default_ret:()
      env
  with
  | Lwt.Canceled ->
    (* It's fine for parallelizable commands to be canceled - they'll be run again later *)
    Lwt.return_unit

let handle_nonparallelizable_persistent_unsafe ~genv ~workload ~client ~profiling env =
  let workload = workload ~client in
  run_command_in_serial ~genv ~env ~profiling ~workload

let handle_nonparallelizable_persistent ~genv ~client_id ~request ~workload env =
  wrap_persistent_handler
    handle_nonparallelizable_persistent_unsafe
    ~genv
    ~client_id
    ~request
    ~workload
    ~default_ret:env
    env

let enqueue_persistent
    (genv : ServerEnv.genv) (client_id : LspProt.client_id) (request : LspProt.request_with_metadata)
    : unit =
  let name = request |> fst |> LspProt.string_of_request in
  match get_persistent_handler ~genv ~client_id ~request with
  | Handle_persistent_immediately workload ->
    handle_persistent_immediately ~genv ~client_id ~request ~workload
  | Handle_parallelizable_persistent workload ->
    let workload = handle_parallelizable_persistent ~genv ~client_id ~request ~name ~workload in
    ServerMonitorListenerState.push_new_parallelizable_workload ~name workload
  | Handle_nonparallelizable_persistent workload ->
    let workload = handle_nonparallelizable_persistent ~genv ~client_id ~request ~workload in
    ServerMonitorListenerState.push_new_workload ~name workload
