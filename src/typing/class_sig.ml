(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module Ast = Flow_ast
module Flow = Flow_js
open Reason
open Utils_js
include Class_sig_intf

module Make (Env : Env_sig.S) (Abnormal : Abnormal_sig.S with module Env := Env) (F : Func_sig.S) =
struct
  type func_sig = F.t

  type func_params_tast = F.func_params_tast

  type set_asts =
    func_params_tast option
    * (ALoc.t, ALoc.t * Type.t) Ast.Function.body option
    * (ALoc.t, ALoc.t * Type.t) Ast.Expression.t option ->
    unit

  type set_type = Type.t -> unit

  type field =
    | Annot of Type.t
    | Infer of func_sig * set_asts

  type field' = ALoc.t option * Polarity.t * field

  type typeapp = ALoc.t * Type.t * Type.t list option

  type extends =
    | Explicit of typeapp
    | Implicit of { null: bool }

  type class_super = {
    extends: extends;
    mixins: typeapp list;
    (* declare class only *)
    implements: typeapp list;
    this_tparam: Type.typeparam;
    this_t: Type.t;
  }

  type interface_super = {
    inline: bool;
    (* Anonymous interface, can appear anywhere inside a type *)
    extends: typeapp list;
    callable: bool;
  }

  type super =
    | Interface of interface_super
    | Class of class_super

  type func_info = ALoc.t option * func_sig * set_asts * set_type

  type signature = {
    reason: reason;
    fields: field' SMap.t;
    private_fields: field' SMap.t;
    proto_fields: field' SMap.t;
    (* Multiple function signatures indicates an overloaded method. Note that
       function signatures are stored in reverse definition order. *)
    methods: func_info Nel.t SMap.t;
    private_methods: func_info SMap.t;
    getters: func_info SMap.t;
    setters: func_info SMap.t;
    calls: Type.t list;
  }

  type t = {
    id: ALoc.id;
    tparams: Type.typeparams;
    tparams_map: Type.t SMap.t;
    super: super;
    (* Multiple function signatures indicates an overloaded constructor. Note that
       function signatures are stored in reverse definition order. *)
    constructor: func_info list;
    static: signature;
    instance: signature;
  }

  let empty id reason tparams tparams_map super =
    let empty_sig reason =
      {
        reason;
        fields = SMap.empty;
        private_fields = SMap.empty;
        proto_fields = SMap.empty;
        methods = SMap.empty;
        private_methods = SMap.empty;
        getters = SMap.empty;
        setters = SMap.empty;
        calls = [];
      }
    in
    let constructor = [] in
    let static =
      let reason = update_desc_reason (fun desc -> RStatics desc) reason in
      empty_sig reason
    in
    let instance = empty_sig reason in
    { id; tparams; tparams_map; super; constructor; static; instance }

  let structural x =
    match x.super with
    | Interface _ -> true
    | Class _ -> false

  let inst_kind x =
    match x.super with
    | Interface { inline; _ } -> Type.InterfaceKind { inline }
    | Class _ -> Type.ClassKind

  let map_sig ~static f s =
    if static then
      { s with static = f s.static }
    else
      { s with instance = f s.instance }

  let with_sig ~static f s =
    if static then
      f s.static
    else
      f s.instance

  let add_private_field name loc polarity field =
    map_sig (fun s ->
        { s with private_fields = SMap.add name (Some loc, polarity, field) s.private_fields }
    )

  let add_private_method ~static name loc fsig ~set_asts ~set_type x =
    let func_info = (Some loc, fsig, set_asts, set_type) in
    map_sig
      ~static
      (fun s -> { s with private_methods = SMap.add name func_info s.private_methods })
      x

  let public_fields_of_signature ~static s =
    ( if static then
      s.static
    else
      s.instance
    )
      .fields

  let private_fields_of_signature ~static s =
    ( if static then
      s.static
    else
      s.instance
    )
      .private_fields

  let add_constructor loc fsig ?(set_asts = ignore) ?(set_type = ignore) s =
    { s with constructor = [(loc, F.to_ctor_sig fsig, set_asts, set_type)] }

  let add_default_constructor reason s =
    let fsig = F.default_constructor reason in
    add_constructor None fsig s

  let append_constructor loc fsig ?(set_asts = ignore) ?(set_type = ignore) s =
    { s with constructor = (loc, F.to_ctor_sig fsig, set_asts, set_type) :: s.constructor }

  let add_field' ~static name fld x =
    let flat = static || structural x in
    map_sig
      ~static
      (fun s ->
        {
          s with
          fields = SMap.add name fld s.fields;
          proto_fields =
            ( if flat then
              SMap.remove name s.proto_fields
            else
              s.proto_fields
            );
          methods =
            ( if flat then
              SMap.remove name s.methods
            else
              s.methods
            );
          getters =
            ( if flat then
              SMap.remove name s.getters
            else
              s.getters
            );
          setters =
            ( if flat then
              SMap.remove name s.setters
            else
              s.setters
            );
        })
      x

  let add_field ~static name loc polarity field x =
    add_field' ~static name (Some loc, polarity, field) x

  let add_indexer ~static polarity ~key ~value x =
    x
    |> add_field' ~static "$key" (None, Polarity.Neutral, Annot key)
    |> add_field' ~static "$value" (None, polarity, Annot value)

  let add_name_field x =
    let r = update_desc_reason (fun desc -> RNameProperty desc) x.instance.reason in
    let t = Type.StrT.why r |> Type.with_trust Trust.bogus_trust in
    add_field' ~static:true "name" (None, Polarity.Neutral, Annot t) x

  let add_proto_field name loc polarity field x =
    map_sig
      ~static:false
      (fun s ->
        {
          s with
          proto_fields = SMap.add name (Some loc, polarity, field) s.proto_fields;
          methods = SMap.remove name s.methods;
          getters = SMap.remove name s.getters;
          setters = SMap.remove name s.setters;
        })
      x

  let add_method ~static name loc fsig ?(set_asts = ignore) ?(set_type = ignore) x =
    let flat = static || structural x in
    let func_info = (Some loc, fsig, set_asts, set_type) in
    map_sig
      ~static
      (fun s ->
        {
          s with
          fields =
            ( if flat then
              SMap.remove name s.fields
            else
              s.fields
            );
          proto_fields = SMap.remove name s.proto_fields;
          methods = SMap.add name (Nel.one func_info) s.methods;
          getters = SMap.remove name s.getters;
          setters = SMap.remove name s.setters;
        })
      x

  (* Appending a method builds a list of function signatures. This implements the
     bahvior of interfaces and declared classes, which interpret duplicate
     definitions as branches of a single overloaded method. *)
  let append_method ~static name loc fsig ?(set_asts = ignore) ?(set_type = ignore) x =
    let flat = static || structural x in
    let func_info = (Some loc, fsig, set_asts, set_type) in
    map_sig
      ~static
      (fun s ->
        {
          s with
          fields =
            ( if flat then
              SMap.remove name s.fields
            else
              s.fields
            );
          proto_fields = SMap.remove name s.proto_fields;
          methods =
            (match SMap.find_opt name s.methods with
            | Some fsigs -> SMap.add name (Nel.cons func_info fsigs) s.methods
            | None -> SMap.add name (Nel.one func_info) s.methods);
          getters = SMap.remove name s.getters;
          setters = SMap.remove name s.setters;
        })
      x

  let append_call ~static t = map_sig ~static (fun s -> { s with calls = t :: s.calls })

  let add_getter ~static name loc fsig ?(set_asts = ignore) ?(set_type = ignore) x =
    let flat = static || structural x in
    let func_info = (Some loc, fsig, set_asts, set_type) in
    map_sig
      ~static
      (fun s ->
        {
          s with
          fields =
            ( if flat then
              SMap.remove name s.fields
            else
              s.fields
            );
          proto_fields = SMap.remove name s.proto_fields;
          methods = SMap.remove name s.methods;
          getters = SMap.add name func_info s.getters;
        })
      x

  let add_setter ~static name loc fsig ?(set_asts = ignore) ?(set_type = ignore) x =
    let flat = static || structural x in
    let func_info = (Some loc, fsig, set_asts, set_type) in
    map_sig
      ~static
      (fun s ->
        {
          s with
          fields =
            ( if flat then
              SMap.remove name s.fields
            else
              s.fields
            );
          proto_fields = SMap.remove name s.proto_fields;
          methods = SMap.remove name s.methods;
          setters = SMap.add name func_info s.setters;
        })
      x

  let mem_constructor { constructor; _ } = constructor <> []

  let mem_field x = with_sig (fun s -> SMap.mem x s.fields)

  let iter_methods_with_name f s =
    SMap.iter (f %> Nel.iter) s.methods;
    SMap.iter f s.private_methods;
    SMap.iter f s.getters;
    SMap.iter f s.setters

  let iter_methods f = iter_methods_with_name (fun _ -> f)

  (* TODO? *)
  let subst_field cx map (loc, polarity, field) =
    ( loc,
      polarity,
      match field with
      | Annot t -> Annot (Flow.subst cx map t)
      | Infer (fsig, set_asts) -> Infer (F.subst cx map fsig, set_asts)
    )

  let subst_sig cx map s =
    let subst_func_sig (loc, sig_, f, g) = (loc, F.subst cx map sig_, f, g) in
    {
      reason = s.reason;
      fields = SMap.map (subst_field cx map) s.fields;
      private_fields = SMap.map (subst_field cx map) s.private_fields;
      proto_fields = SMap.map (subst_field cx map) s.proto_fields;
      methods = SMap.map (Nel.map subst_func_sig) s.methods;
      private_methods = SMap.map subst_func_sig s.private_methods;
      getters = SMap.map subst_func_sig s.getters;
      setters = SMap.map subst_func_sig s.setters;
      calls = Base.List.map ~f:(Flow.subst cx map) s.calls;
    }

  let subst_typeapp cx map (loc, c, targs) =
    let c = Flow.subst cx map c in
    let targs = Base.Option.map ~f:(Base.List.map ~f:(Flow.subst cx map)) targs in
    (loc, c, targs)

  let subst_extends cx map = function
    | Explicit tapp -> Explicit (subst_typeapp cx map tapp)
    | Implicit { null = _ } as extends -> extends

  let subst_super cx map = function
    | Interface { inline; extends; callable } ->
      Interface { inline; extends = Base.List.map ~f:(subst_typeapp cx map) extends; callable }
    | Class { extends; mixins; implements; this_t; this_tparam } ->
      let this_tparam_loc = aloc_of_reason this_tparam.Type.reason in
      let this_t_annot_reason = annot_reason ~annot_loc:this_tparam_loc this_tparam.Type.reason in
      Class
        {
          extends = subst_extends cx map extends;
          mixins = Base.List.map ~f:(subst_typeapp cx map) mixins;
          implements = Base.List.map ~f:(subst_typeapp cx map) implements;
          this_t = Flow.reposition_reason cx this_t_annot_reason (Flow.subst cx map this_t);
          this_tparam;
        }

  let this_tparam x =
    match x.super with
    | Class { this_tparam; _ } -> Some this_tparam
    | Interface _ -> None

  let this_t x =
    match x.super with
    | Class { this_t; _ } -> Some this_t
    | Interface _ -> None

  let this_or_mixed loc = this_t %> Base.Option.value ~default:(Type.dummy_this loc)

  let this_or_mixed_of_t ~static x =
    let loc =
      if static then
        aloc_of_reason x.static.reason
      else
        aloc_of_reason x.instance.reason
    in
    let this_t = this_or_mixed loc x in
    if static then
      TypeUtil.class_type this_t
    else
      this_t

  let tparams_with_this tparams this_tp =
    (* Use the loc for the original tparams, or just the loc for the this type if there are no
       * tparams *)
    let loc = Base.Option.value_map ~default:(aloc_of_reason this_tp.Type.reason) ~f:fst tparams in
    (* Add the type of `this` to the end of the list of type
       parameters. Remember, order is important, since we don't have recursive
       bounds (aka F-bounds): the bound of This refers to all the other type
       parameters! *)
    let tparams_lst = Type.TypeParams.to_list tparams @ [this_tp] in
    (* Obviously there is at least one element since we just added `this_tp` *)
    let tparams_nel = Base.Option.value_exn (Nel.of_list tparams_lst) in
    Some (loc, tparams_nel)

  let check_with_generics cx f x =
    let tparams_with_this =
      this_tparam x |> Base.Option.value_map ~default:x.tparams ~f:(tparams_with_this x.tparams)
    in
    Flow_js_utils.check_with_generics cx (Type.TypeParams.to_list tparams_with_this) (fun map ->
        f
          {
            id = x.id;
            tparams = x.tparams;
            tparams_map = SMap.map (Flow.subst cx map) x.tparams_map;
            super = subst_super cx map x.super;
            constructor =
              Base.List.map
                ~f:(fun (loc, sig_, g, h) -> (loc, F.subst cx map sig_, g, h))
                x.constructor;
            static = subst_sig cx map x.static;
            instance = subst_sig cx map x.instance;
          }
    )

  let to_field (loc, polarity, field) =
    let t =
      match field with
      | Annot t -> t
      | Infer (fsig, _) -> F.gettertype fsig
    in
    Type.Field (loc, t, polarity)

  let to_method cx this_default (loc, fsig, _, _) =
    Type.Method (loc, F.methodtype cx this_default fsig)

  let to_prop_map to_prop_converter cx =
    SMap.map to_prop_converter %> NameUtils.namemap_of_smap %> Context.generate_property_map cx

  let fields_to_prop_map = to_prop_map to_field

  let methods_to_prop_map ~cx ~this_default = to_prop_map (to_method cx this_default) cx

  let elements cx ~this ?constructor s super =
    (* To determine the default `this` parameter for a method without `this` annotation, we
       default to the instance/static `this` type *)
    let this_default (x : F.t) =
      match (x.F.body, super) with
      (* We can use mixed for declared class methods here for two reasons:
         1) They can never be unbound
         2) They have no body
      *)
      | (None, Class _) -> Type.implicit_mixed_this x.F.reason
      | (Some _, Class _) ->
        TypeUtil.mod_reason_of_t Reason.(update_desc_reason (fun desc -> RImplicitThis desc)) this
      | (_, Interface _) -> x.F.reason |> Type.implicit_mixed_this
    in
    let methods =
      (* If this is an overloaded method, create an intersection, attributed
         to the first declared function signature. If there is a single
         function signature for this method, simply return the method type. *)
      let open Type in
      let open TypeUtil in
      SMap.mapi
        (fun _name xs ->
          let ms =
            Nel.rev_map
              (fun (loc, x, _, set_type) -> (loc, F.methodtype cx (this_default x) x, set_type))
              xs
          in
          (* Keep track of these before intersections are merged, to enable
           * type information on every member of the intersection. *)
          ms |> Nel.iter (fun (loc, t, set_type) -> Base.Option.iter loc ~f:(fun _loc -> set_type t));
          match ms with
          | ((loc, t, _), []) -> (loc, t)
          | ((loc0, t0, _), (_, t1, _) :: ts) ->
            let ts = Base.List.map ~f:(fun (_loc, t, _) -> t) ts in
            (loc0, IntersectionT (reason_of_t t0, InterRep.make t0 t1 ts)))
        s.methods
    in
    let () =
      SMap.iter
        (fun _name (loc, x, _, set_type) ->
          Base.Option.iter loc ~f:(fun _loc -> set_type (F.methodtype cx (this_default x) x)))
        s.private_methods
    in
    (* Re-add the constructor as a method. *)
    let methods =
      match constructor with
      | Some t -> SMap.add "constructor" t methods
      | None -> methods
    in
    (* If there is a both a getter and a setter, then flow the setter type to
       the getter. Otherwise just use the getter type or the setter type *)
    let getters =
      SMap.map (fun (loc, t, _, set_type) -> (loc, F.gettertype t, set_type)) s.getters
    in
    let setters =
      SMap.map (fun (loc, t, _, set_type) -> (loc, F.settertype t, set_type)) s.setters
    in
    (* Register getters and setters with the typed AST *)
    let register_accessors =
      SMap.iter (fun _ (loc, t, set_type) -> Base.Option.iter ~f:(fun _ -> set_type t) loc)
    in
    register_accessors getters;
    register_accessors setters;

    let getters_and_setters =
      SMap.merge
        (fun _ getter setter ->
          match (getter, setter) with
          | (Some (loc1, t1, _), Some (loc2, t2, _)) -> Some (Type.GetSet (loc1, t1, loc2, t2))
          | (Some (loc, t, _), None) -> Some (Type.Get (loc, t))
          | (None, Some (loc, t, _)) -> Some (Type.Set (loc, t))
          | _ -> None)
        getters
        setters
    in
    let fields = SMap.map to_field s.fields in
    let methods = SMap.map (fun (loc, t) -> Type.Method (loc, t)) methods in
    (* Treat proto fields as methods, as they are on the proto object *)
    let methods =
      SMap.fold (fun name fld acc -> SMap.add name (to_field fld) acc) s.proto_fields methods
    in
    (* Treat getters and setters as methods *)
    let methods = SMap.union getters_and_setters methods in
    let call =
      match List.rev s.calls with
      | [] -> None
      | [t] -> Some t
      | t0 :: t1 :: ts ->
        let open Type in
        let open TypeUtil in
        let t = IntersectionT (reason_of_t t0, InterRep.make t0 t1 ts) in
        Some t
    in
    (* Only un-initialized fields require annotations, so determine now
     * (syntactically) which fields have initializers *)
    let initialized_fields =
      SMap.fold
        (fun x (_, _, field) acc ->
          match field with
          | Annot _ -> acc
          | Infer _ -> SSet.add x acc)
        s.fields
        SSet.empty
    in
    (initialized_fields, fields, methods, call)

  let specialize cx targs c =
    let open Type in
    let open TypeUtil in
    let reason = reason_of_t c in
    Tvar.mk_where cx reason (fun tvar ->
        Flow.flow cx (c, SpecializeT (unknown_use, reason, reason, None, targs, tvar))
    )

  let statictype cx static_proto x =
    let s = x.static in
    let (inited_fields, fields, methods, call) =
      let loc = aloc_of_reason x.static.reason in
      elements cx ~this:(this_or_mixed loc x |> TypeUtil.class_type) s x.super
    in
    let props =
      SMap.union fields methods ~combine:(fun _ _ ->
          Utils_js.assert_false
            (Utils_js.spf
               "static fields and methods must be disjoint: %s"
               (Debug_js.dump_reason cx s.reason)
            )
      )
      |> NameUtils.namemap_of_smap
    in
    (* Statics are not exact, because we allow width subtyping between them.
       Specifically, given class A and class B extends A, Class<B> <: Class<A>. *)
    let static =
      Obj_type.mk_with_proto cx s.reason ~props ?call static_proto ~obj_kind:Type.Inexact
    in
    Type.(
      match static with
      | DefT (_, _, ObjT o) -> (inited_fields, o)
      | _ -> failwith "statics must be an ObjT"
    )

  let insttype cx ~initialized_static_fields s =
    let constructor =
      (* Constructors do not bind `this` *)
      let ts =
        List.rev_map
          (fun (loc, t, _, _) ->
            (loc, F.methodtype cx (Type.dummy_this (aloc_of_reason s.instance.reason)) t))
          s.constructor
      in
      match ts with
      | [] -> None
      | [x] -> Some x
      | (loc0, t0) :: (_loc1, t1) :: ts ->
        let ts = Base.List.map ~f:snd ts in
        let open Type in
        let open TypeUtil in
        let t = IntersectionT (reason_of_t t0, InterRep.make t0 t1 ts) in
        Some (loc0, t)
    in
    let type_args =
      Base.List.map
        ~f:(fun { Type.name; reason; polarity; _ } ->
          let t = SMap.find name s.tparams_map in
          (name, reason, t, polarity))
        (Type.TypeParams.to_list s.tparams)
    in
    let (initialized_fields, fields, methods, call) =
      let loc = aloc_of_reason s.instance.reason in
      elements cx ~this:(this_or_mixed loc s) ?constructor s.instance s.super
    in
    {
      Type.class_id = s.id;
      type_args;
      own_props = Context.generate_property_map cx (NameUtils.namemap_of_smap fields);
      proto_props = Context.generate_property_map cx (NameUtils.namemap_of_smap methods);
      inst_call_t = Base.Option.map call ~f:(Context.make_call_prop cx);
      initialized_fields;
      initialized_static_fields;
      has_unknown_react_mixins = false;
      inst_kind = inst_kind s;
    }

  let mk_this self cx reason tparams =
    (* We haven't computed the instance type yet, but we can still capture a
       reference to it using the class name (as long as the class has a name).
       We need this reference to constrain the `this` in the class. *)
    let rec_instance_type =
      match tparams with
      | None -> Flow.mk_instance cx reason self
      | _ ->
        let open Type in
        let targs =
          Base.List.map ~f:(fun tp -> BoundT (tp.Type.reason, tp.name)) (TypeParams.to_list tparams)
        in
        TypeUtil.typeapp reason self targs
    in
    let this_reason = replace_desc_reason RThisType reason in
    let this_tp =
      {
        Type.name = "this";
        reason = this_reason;
        bound = rec_instance_type;
        polarity = Polarity.Positive;
        default = None;
        is_this = true;
      }
    in
    (this_tp, Type.BoundT (this_reason, "this"))

  let supertype cx x =
    let super_reason = update_desc_reason (fun d -> RSuperOf d) x.instance.reason in
    let static_reason = x.static.reason in
    let open Type in
    let open TypeUtil in
    match x.super with
    | Interface { inline = _; extends; callable } ->
      let extends =
        Base.List.map
          ~f:(fun (annot_loc, c, targs_opt) ->
            match targs_opt with
            | None ->
              let reason = annot_reason ~annot_loc @@ repos_reason annot_loc (reason_of_t c) in
              Flow.mk_instance cx reason c
            | Some targs -> typeapp_annot annot_loc c targs)
          extends
      in
      (* If the interface definition includes a callable property, add the
         function prototype to the super type *)
      let extends =
        if callable then
          FunProtoT super_reason :: extends
        else
          extends
      in
      (* Interfaces support multiple inheritance, which is modelled as an
         intersection of super types. TODO: Instead of using an intersection for
         this, we should resolve the extends and build a flattened type, and just
         use FunProtoT/ObjProtoT as the prototype *)
      let super =
        match extends with
        | [] -> ObjProtoT super_reason
        | [t] -> t
        | t0 :: t1 :: ts -> IntersectionT (super_reason, InterRep.make t0 t1 ts)
      in
      (* interfaces don't have statics *)
      let static_proto = Type.NullProtoT static_reason in
      (super, static_proto)
    | Class { extends; mixins; this_t; _ } ->
      let (extends_t, static_proto) =
        match extends with
        | Explicit (annot_loc, c, targs) ->
          (* Eagerly specialize when there are no targs *)
          let c =
            if targs = None then
              specialize cx targs c
            else
              c
          in
          let t = this_typeapp ~annot_loc c this_t targs in
          (* class B extends A {}; B.__proto__ === A *)
          let static_proto = class_type ~annot_loc t in
          (t, static_proto)
        | Implicit { null } ->
          let t =
            if null then
              NullProtoT super_reason
            else
              ObjProtoT super_reason
          in
          (* class A {}; A.__proto__ === Function.prototype *)
          let static_proto = FunProtoT static_reason in
          (t, static_proto)
      in
      let mixins_rev =
        List.rev_map
          (fun (annot_loc, c, targs) ->
            (* Eagerly specialize when there are no targs *)
            let c =
              if targs = None then
                specialize cx targs c
              else
                c
            in
            this_typeapp ~annot_loc c this_t targs)
          mixins
      in
      let super =
        match List.rev_append mixins_rev [extends_t] with
        | [] -> failwith "impossible"
        | [t] -> t
        | t0 :: t1 :: ts -> IntersectionT (super_reason, InterRep.make t0 t1 ts)
      in
      (super, static_proto)

  let thistype cx x =
    let { static = { reason = sreason; _ }; instance = { reason; _ }; _ } = x in
    let (super, static_proto) = supertype cx x in
    let implements =
      match x.super with
      | Interface _ -> []
      | Class { implements; _ } ->
        Base.List.map
          ~f:(fun (annot_loc, c, targs_opt) ->
            match targs_opt with
            | None ->
              let reason =
                annot_reason ~annot_loc @@ repos_reason annot_loc (TypeUtil.reason_of_t c)
              in
              Flow.mk_instance cx reason c
            | Some targs -> TypeUtil.typeapp_annot annot_loc c targs)
          implements
    in
    let (initialized_static_fields, static_objtype) = statictype cx static_proto x in
    let insttype = insttype cx ~initialized_static_fields x in
    let open Type in
    let static = DefT (sreason, bogus_trust (), ObjT static_objtype) in
    DefT (reason, bogus_trust (), InstanceT (static, super, implements, insttype))

  let check_methods cx def_reason x =
    let open Type in
    let self =
      match x.super with
      | Interface _ -> thistype cx x
      | Class { this_t; _ } -> this_t
    in
    let check_method msig ~static name id_loc =
      (* The this parameter of the method, if annotated, must be a supertype
         of the instance *)
      F.check_with_generics
        cx
        (fun msig ->
          Base.Option.iter
            ~f:(fun this_param ->
              let self =
                if static then
                  TypeUtil.class_type self
                else
                  self
              in
              let reason = mk_reason (RMethod (Some name)) id_loc in
              let use_op = Op (ClassMethodDefinition { def = reason; name = def_reason }) in
              Flow.flow cx (self, UseT (use_op, this_param)))
            (F.this_param msig.F.fparams))
        msig
    in

    with_sig
      ~static:true
      (iter_methods_with_name (fun name (loc, msig, _, _) ->
           (* Constructors don't bind this *)
           Base.Option.iter ~f:(check_method msig ~static:true name) loc
       )
      )
      x;

    with_sig
      ~static:false
      (iter_methods_with_name (* Constructors don't bind this *) (fun name (loc, msig, _, _) ->
           Base.Option.iter ~f:(check_method msig ~static:false name) loc
       )
      )
      x

  let check_implements cx def_reason x =
    match x.super with
    | Interface _ -> ()
    | Class { implements; _ } ->
      let this = thistype cx x in
      let reason = x.instance.reason in
      let open Type in
      let open TypeUtil in
      List.iter
        (fun (annot_loc, c, targs_opt) ->
          let i =
            match targs_opt with
            | None ->
              let reason = annot_reason ~annot_loc @@ repos_reason annot_loc (reason_of_t c) in
              Flow.mk_instance cx reason c
            | Some targs -> typeapp_annot annot_loc c targs
          in
          let use_op =
            Op (ClassImplementsCheck { def = def_reason; name = reason; implements = reason_of_t i })
          in
          Flow.flow cx (i, ImplementsT (use_op, this)))
        implements

  let check_super cx def_reason x =
    let reason = x.instance.reason in
    let open Type in
    let open TypeUtil in
    (* NOTE: SuperT ignores the constructor anyway, so we don't pass it here.
       Call properties are also ignored, so we ignore that result. *)
    (* The this parameter of a class method is irrelvant for class subtyping, since
       dynamic dispatch enforces that the method is called on the right subclass
       at runtime even if the static type is a supertype. *)
    let inst_loc = aloc_of_reason reason in
    let (_, own, proto, _call) =
      elements ~this:(this_or_mixed inst_loc x) cx ?constructor:None x.instance x.super
    in
    let static =
      (* NOTE: The own, proto maps are disjoint by construction. *)
      let (_, own, proto, _call) =
        elements ~this:(this_or_mixed inst_loc x |> class_type) cx x.static x.super
      in
      SMap.union own proto
    in
    SMap.iter
      (fun x p1 ->
        match SMap.find_opt x proto with
        | None -> ()
        | Some p2 ->
          let use_op =
            Op
              (ClassOwnProtoCheck
                 {
                   prop = OrdinaryName x;
                   own_loc = Property.first_loc p1;
                   proto_loc = Property.first_loc p2;
                 }
              )
          in
          let propref = Named (reason, OrdinaryName x) in
          Flow.flow_p cx ~use_op reason reason propref (p1, p2))
      own;

    let (super, _) = supertype cx x in
    let use_op =
      Op (ClassExtendsCheck { def = def_reason; name = reason; extends = reason_of_t super })
    in
    Flow.flow
      cx
      ( super,
        SuperT
          ( use_op,
            reason,
            Derived
              {
                own = NameUtils.namemap_of_smap own;
                proto = NameUtils.namemap_of_smap proto;
                static = NameUtils.namemap_of_smap static;
              }
          )
      )

  (* TODO: Ideally we should check polarity for all class types, but this flag is
     flipped off for interface/declare class currently. *)
  let classtype cx ?(check_polarity = true) x =
    let this = thistype cx x in
    let tparams_with_this =
      this_tparam x |> Base.Option.value_map ~default:x.tparams ~f:(tparams_with_this x.tparams)
    in
    begin
      match tparams_with_this with
      | Some (_, tps) when check_polarity ->
        (* TODO: use tparams_map instead of calculating this here *)
        let tparams = Nel.fold_left (fun acc tp -> SMap.add tp.Type.name tp acc) SMap.empty tps in
        Flow.check_polarity cx tparams Polarity.Positive this
      | _ -> ()
    end;
    let open TypeUtil in
    let (t_inner, t_outer) =
      if structural x then
        let class_type = class_type ~structural:true this in
        (class_type, class_type)
      else
        (this_class_type this true, this_class_type this false)
    in
    let poly t = poly_type_of_tparams (Context.generate_poly_id cx) x.tparams t in
    (poly t_inner, poly t_outer)

  (* Processes the bodies of instance and static class members. *)
  let toplevels cx ~private_property_map ~instance_this_type ~static_this_type x =
    let open Type in
    Env.in_lex_scope (fun () ->
        let new_entry ?(state = Scope.State.Initialized) t =
          Scope.Entry.new_let
            ~loc:(TypeUtil.loc_of_t (TypeUtil.type_t_of_annotated_or_inferred t))
            ~state
            ~provider:(TypeUtil.type_t_of_annotated_or_inferred t)
            t
        in

        let method_ this_recipe super ~set_asts f =
          let save_return = Abnormal.clear_saved Abnormal.Return in
          let save_throw = Abnormal.clear_saved Abnormal.Throw in
          let (_, params_ast, body_ast, init_ast) =
            f |> F.check_with_generics cx (F.toplevels None cx this_recipe super)
          in
          set_asts (params_ast, body_ast, init_ast);
          ignore (Abnormal.swap_saved Abnormal.Return save_return);
          ignore (Abnormal.swap_saved Abnormal.Throw save_throw)
        in
        let field this_recipe super _name (_, _, value) =
          match value with
          | Annot _ -> ()
          | Infer (fsig, set_asts) -> method_ this_recipe super ~set_asts fsig
        in
        let (instance_this_default, static_this_default, super, static_super) =
          let super_reason = update_desc_reason (fun d -> RSuperOf d) x.instance.reason in
          match x.super with
          | Interface _ -> failwith "tried to evaluate toplevel of interface"
          | Class { extends; this_t; _ } ->
            let (super, static_super) =
              match extends with
              | Explicit (annot_loc, c, targs) ->
                (* Eagerly specialize when there are no targs *)
                (* TODO: We can also specialize when there are targs, because this
                   code executes within check_with_generics. However, the type normalizer
                   expects a PolyT here. *)
                let c =
                  if targs = None then
                    specialize cx targs c
                  else
                    c
                in
                let t = TypeUtil.this_typeapp ~annot_loc c this_t targs in
                (t, TypeUtil.class_type ~annot_loc t)
              | Implicit { null } ->
                Type.
                  ( ( if null then
                      NullProtoT super_reason
                    else
                      ObjProtoT super_reason
                    ),
                    FunProtoT super_reason
                  )
                
            in

            (this_t, TypeUtil.class_type this_t, super, static_super)
        in

        let this_recipe default fparams =
          let t = F.this_param fparams |> TypeUtil.annotated_or_inferred_of_option ~default in
          let this = new_entry t in
          (TypeUtil.type_t_of_annotated_or_inferred t, this)
        in
        let instance_this_recipe = this_recipe instance_this_default in
        let static_this_recipe = this_recipe static_this_default in

        (* Bind private fields and methods to the environment *)
        Env.bind_class
          cx
          x.id
          private_property_map
          (fields_to_prop_map cx x.static.private_fields)
          (methods_to_prop_map ~cx ~this_default:instance_this_type x.instance.private_methods)
          (methods_to_prop_map ~cx ~this_default:static_this_type x.static.private_methods);

        x
        |> with_sig ~static:true (fun s ->
               (* process static methods and fields *)
               let super = new_entry (Inferred static_super) in
               iter_methods
                 (fun (_loc, f, set_asts, _) -> method_ static_this_recipe super ~set_asts f)
                 s;
               SMap.iter (field static_this_recipe super) s.fields;
               SMap.iter (field static_this_recipe super) s.private_fields
           );

        x
        |> with_sig ~static:false (fun s ->
               (* process constructor *)
               begin
                 (* When in a derived constructor, leave this and super undeclared, the
                    same way let-scoped variables are stored in the environment before
                    their declaration. Once we see a super() call, the bindings are
                    treated as declared and initialized. This protects against using
                    `this` before it is allocated by the superclass. *)
                 let derived_ctor =
                   match x.super with
                   | Class { extends = Explicit _; _ } -> true
                   | _ -> false
                 in
                 let new_entry t =
                   if derived_ctor then
                     new_entry t ~state:Scope.State.Undeclared
                   else
                     new_entry t
                 in
                 (* This parameters are banned in constructors *)
                 let (this, super) =
                   (new_entry (Inferred instance_this_default), new_entry (Inferred super))
                 in
                 let this_recipe _ = (instance_this_default, this) in
                 x.constructor
                 |> List.iter (fun (_, fsig, set_asts, _) ->
                        method_ this_recipe super ~set_asts fsig
                    )
               end;

               (* process instance methods and fields *)
               let super = new_entry (Inferred super) in
               iter_methods
                 (fun (_, msig, set_asts, _) -> method_ instance_this_recipe super ~set_asts msig)
                 s;
               SMap.iter (field instance_this_recipe super) s.fields;
               SMap.iter (field instance_this_recipe super) s.private_fields;
               SMap.iter (field instance_this_recipe super) s.proto_fields
           )
    )

  module This = struct
    let is_bound_to_empty { super; _ } =
      Type.(
        match super with
        | Class { this_t = DefT (_, _, EmptyT); _ } -> true
        | _ -> false
      )

    exception FoundInClass

    class detector =
      object
        inherit [ALoc.t] Flow_ast_mapper.mapper as super

        method! generic_identifier_type (git : (ALoc.t, ALoc.t) Ast.Type.Generic.Identifier.t) =
          let open Ast.Type.Generic.Identifier in
          match git with
          | Unqualified (_, { Ast.Identifier.name = "this"; comments = _ }) -> raise FoundInClass
          | _ -> super#generic_identifier_type git
      end

    let in_class c =
      try
        (new detector)#class_ ALoc.none c |> ignore;
        false
      with
      | FoundInClass -> true
  end
end
