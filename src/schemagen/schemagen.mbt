// 解決済みメタデータから GraphQL スキーマ (@schema.Schema) を生成する。
// 生成物は Hasura 風: query_root 上の <model> / <model>_by_pk、
// <type>_bool_exp / <scalar>_comparison_exp / <type>_order_by / order_by enum

///|
fn name(s : String) -> @graphql.Name {
  @graphql.Name::new_unchecked(s)
}

///|
fn tname(s : String) -> @graphql.TypeName {
  @graphql.TypeName(name(s))
}

///|
fn named_type(s : String, nullable : Bool) -> @graphql.GType {
  { base: Named(tname(s)), nullable }
}

///|
fn list_of(inner : @graphql.GType, nullable : Bool) -> @graphql.GType {
  { base: List(inner), nullable }
}

///|
fn scalar_name(t : @graphql.GType) -> String {
  match t.base {
    Named(n) => n.as_str()
    List(inner) => scalar_name(inner)
  }
}

///|
fn mk_input_field(
  fname : String,
  ty : @graphql.GType,
  info : @schema.Annotation,
) -> @schema.Namespaced[@schema.SInputField] {
  @schema.allow_all_namespaced(@schema.SInputField::{
    name: name(fname),
    description: None,
    info,
    field_type: ty,
    default_value: None,
    deprecation_status: NotDeprecated,
  })
}

///|
fn mk_field(
  fname : String,
  ty : @graphql.GType,
  info : @schema.Annotation,
  arguments : @sorted_map.SortedMap[
    @graphql.Name,
    @schema.Namespaced[@schema.SInputField],
  ],
) -> @schema.Namespaced[@schema.SField] {
  @schema.allow_all_namespaced(@schema.SField::{
    name: name(fname),
    description: None,
    info,
    field_type: ty,
    arguments,
    deprecation_status: NotDeprecated,
  })
}

///|
/// 比較演算子入力型 <Scalar>_comparison_exp を作る
fn comparison_exp(scalar : String) -> @schema.TypeInfo {
  let fields : @sorted_map.SortedMap[
    @graphql.Name,
    @schema.Namespaced[@schema.SInputField],
  ] = @sorted_map.SortedMap([])
  let st = named_type(scalar, true)
  for op in ["_eq", "_neq", "_gt", "_gte", "_lt", "_lte"] {
    fields[name(op)] = mk_input_field(op, st, InputArg(BoolExpOperator(op)))
  }
  fields[name("_in")] = mk_input_field(
    "_in",
    list_of(named_type(scalar, false), true),
    InputArg(BoolExpOperator("_in")),
  )
  fields[name("_is_null")] = mk_input_field(
    "_is_null",
    named_type("Boolean", true),
    InputArg(BoolExpOperator("_is_null")),
  )
  if scalar == "String" {
    fields[name("_like")] = mk_input_field(
      "_like",
      named_type("String", true),
      InputArg(BoolExpOperator("_like")),
    )
  }
  @schema.TypeInfo::InputObject({
    name: tname("\{scalar}_comparison_exp"),
    description: None,
    fields,
    directives: [],
  })
}

///|
/// order_by enum (Hasura 互換の 6 値)
fn order_by_enum() -> @schema.TypeInfo {
  let values : @sorted_map.SortedMap[
    @graphql.Name,
    @schema.Namespaced[@schema.SEnumValue],
  ] = @sorted_map.SortedMap([])
  for
    v in [
      "asc", "asc_nulls_first", "asc_nulls_last", "desc", "desc_nulls_first", "desc_nulls_last",
    ] {
    values[name(v)] = @schema.allow_all_namespaced(@schema.SEnumValue::{
      value: name(v),
      description: None,
      deprecation_status: NotDeprecated,
      info: InputArg(EnumValue(v)),
    })
  }
  @schema.TypeInfo::Enum({
    name: tname("order_by"),
    description: None,
    values,
    directives: [],
  })
}

///|
/// メタデータからスキーマを生成
pub fn build_schema(meta : @metadata.Metadata) -> @schema.Schema raise {
  let types : @sorted_map.SortedMap[@graphql.TypeName, @schema.TypeInfo] = @sorted_map.SortedMap([],
  )
  let register = (ti : @schema.TypeInfo) => types[ti.type_name()] = ti

  // 組み込みスカラーと introspection 型
  for s in @schema.builtin_scalars() {
    register(s)
  }
  let (intro_types, intro_root_fields) = @schema.introspection_parts()
  for t in intro_types {
    register(t)
  }
  register(order_by_enum())

  // どのスカラーの comparison_exp が必要か収集しつつオブジェクト型を作る
  let needed_comparison : Map[String, Bool] = Map([])

  // オブジェクト型 (モデルの型 + リレーションフィールド)
  for ot_name, ot in meta.object_types {
    let fields : @sorted_map.SortedMap[
      @graphql.Name,
      @schema.Namespaced[@schema.SField],
    ] = @sorted_map.SortedMap([])
    for f in ot.fields {
      let sfield : @schema.SField = {
        name: name(f.name),
        description: None,
        info: ModelField(f.name),
        field_type: f.field_type,
        arguments: @sorted_map.SortedMap([]),
        deprecation_status: NotDeprecated,
      }
      fields[name(f.name)] = field_visibility(meta, ot_name, f.name, sfield)
    }
    // リレーションシップフィールド
    match meta.relationships.get(ot_name) {
      Some(rels) =>
        for rel in rels {
          let target_model = meta.models.get(rel.target_model).unwrap()
          let target_ot = meta.object_types
            .get(target_model.object_type)
            .unwrap()
          let target_type_name = target_ot.graphql_type_name
          let rel_roles = model_permission_roles(meta, rel.target_model)
          match rel.kind {
            RelObject => {
              let data : @schema.SField = {
                name: name(rel.name),
                description: None,
                info: RelationshipField(rel.name),
                field_type: named_type(target_type_name, true),
                arguments: @sorted_map.SortedMap([]),
                deprecation_status: NotDeprecated,
              }
              fields[name(rel.name)] = @schema.conditional_namespaced(
                data, rel_roles,
              )
            }
            RelArray => {
              let args = model_select_arguments(target_ot.graphql_type_name)
              let data : @schema.SField = {
                name: name(rel.name),
                description: None,
                info: RelationshipField(rel.name),
                field_type: list_of(named_type(target_type_name, false), false),
                arguments: args,
                deprecation_status: NotDeprecated,
              }
              fields[name(rel.name)] = @schema.conditional_namespaced(
                data, rel_roles,
              )
            }
          }
        }
      None => ()
    }
    let tn = @schema.build_typename_field()
    fields[tn.data.name] = tn
    register(
      @schema.TypeInfo::Object({
        name: tname(ot.graphql_type_name),
        description: ot.description,
        fields,
        interfaces: @sorted_map.SortedMap([]),
        directives: [],
      }),
    )
  }

  // bool_exp / order_by 入力型 (モデルがあるオブジェクト型のみ)
  for _, model in meta.models {
    let ot = meta.object_types.get(model.object_type).unwrap()
    let gql_name = ot.graphql_type_name

    // bool_exp
    let bool_fields : @sorted_map.SortedMap[
      @graphql.Name,
      @schema.Namespaced[@schema.SInputField],
    ] = @sorted_map.SortedMap([])
    let bool_exp_name = "\{gql_name}_bool_exp"
    bool_fields[name("_and")] = mk_input_field(
      "_and",
      list_of(named_type(bool_exp_name, false), true),
      InputArg(BoolExpLogical("_and")),
    )
    bool_fields[name("_or")] = mk_input_field(
      "_or",
      list_of(named_type(bool_exp_name, false), true),
      InputArg(BoolExpLogical("_or")),
    )
    bool_fields[name("_not")] = mk_input_field(
      "_not",
      named_type(bool_exp_name, true),
      InputArg(BoolExpLogical("_not")),
    )
    for f in ot.fields {
      if model.filterable_fields.contains(f.name) {
        let scalar = scalar_name(f.field_type)
        needed_comparison[scalar] = true
        bool_fields[name(f.name)] = mk_input_field(
          f.name,
          named_type("\{scalar}_comparison_exp", true),
          InputArg(BoolExpField(f.name)),
        )
      }
    }
    register(
      @schema.TypeInfo::InputObject({
        name: tname(bool_exp_name),
        description: None,
        fields: bool_fields,
        directives: [],
      }),
    )

    // order_by
    let order_fields : @sorted_map.SortedMap[
      @graphql.Name,
      @schema.Namespaced[@schema.SInputField],
    ] = @sorted_map.SortedMap([])
    for f in ot.fields {
      if model.orderable_fields.contains(f.name) {
        order_fields[name(f.name)] = mk_input_field(
          f.name,
          named_type("order_by", true),
          InputArg(OrderByField(f.name)),
        )
      }
    }
    // オブジェクトリレーション越しのソート (対象モデルの order_by 型を参照。
    // 可視性は対象モデルの select 権限に従う)
    match meta.relationships.get(model.object_type) {
      Some(rels) =>
        for rel in rels {
          match rel.kind {
            RelObject => {
              let target_model = meta.models.get(rel.target_model).unwrap()
              let target_ot = meta.object_types
                .get(target_model.object_type)
                .unwrap()
              let rel_roles = model_permission_roles(meta, rel.target_model)
              let data : @schema.SInputField = {
                name: name(rel.name),
                description: None,
                info: InputArg(OrderByRelationship(rel.name)),
                field_type: named_type(
                  "\{target_ot.graphql_type_name}_order_by",
                  true,
                ),
                default_value: None,
                deprecation_status: NotDeprecated,
              }
              order_fields[name(rel.name)] = @schema.conditional_namespaced(
                data, rel_roles,
              )
            }
            RelArray => ()
          }
        }
      None => ()
    }
    register(
      @schema.TypeInfo::InputObject({
        name: tname("\{gql_name}_order_by"),
        description: None,
        fields: order_fields,
        directives: [],
      }),
    )
  }

  // 必要な comparison_exp を登録
  for scalar, _ in needed_comparison {
    register(comparison_exp(scalar))
  }

  // query_root
  let root_fields : @sorted_map.SortedMap[
    @graphql.Name,
    @schema.Namespaced[@schema.SField],
  ] = @sorted_map.SortedMap([])
  for model_name, model in meta.models {
    let ot = meta.object_types.get(model.object_type).unwrap()
    let gql_name = ot.graphql_type_name
    let args = model_select_arguments(gql_name)
    let roles = model_permission_roles(meta, model_name)
    let select_field_name = model.select_many_name
    let select_data : @schema.SField = {
      name: name(select_field_name),
      description: None,
      info: ModelSelect(model_name),
      field_type: list_of(named_type(gql_name, false), false),
      arguments: args,
      deprecation_status: NotDeprecated,
    }
    root_fields[name(select_field_name)] = @schema.conditional_namespaced(
      select_data, roles,
    )
    // 一意取得ルートフィールド (select_uniques 指定 or primary_key 由来)
    let uniques : Array[(String, Array[String])] = if !model.select_uniques.is_empty() {
      model.select_uniques
    } else if !model.primary_key.is_empty() {
      [("\{select_field_name}_by_pk", model.primary_key)]
    } else {
      []
    }
    for unique in uniques {
      let (root_name, key_fields) = unique
      let pk_args : @sorted_map.SortedMap[
        @graphql.Name,
        @schema.Namespaced[@schema.SInputField],
      ] = @sorted_map.SortedMap([])
      for pk in key_fields {
        let f = ot.fields.iter().find_first(x => x.name == pk).unwrap()
        // 一意キー引数は non-null
        let base_scalar = scalar_name(f.field_type)
        pk_args[name(pk)] = mk_input_field(
          pk,
          named_type(base_scalar, false),
          InputArg(ArgPkColumn(pk)),
        )
      }
      let by_pk_data : @schema.SField = {
        name: name(root_name),
        description: None,
        info: ModelSelectByPk(model_name),
        field_type: named_type(gql_name, true),
        arguments: pk_args,
        deprecation_status: NotDeprecated,
      }
      root_fields[name(root_name)] = @schema.conditional_namespaced(
        by_pk_data, roles,
      )
    }
  }
  // introspection ルートフィールド (__schema / __type) を統合
  for entry in intro_root_fields.iter() {
    let (fname, f) = entry
    root_fields[fname] = f
  }
  let tn = @schema.build_typename_field()
  root_fields[tn.data.name] = tn
  register(
    @schema.TypeInfo::Object({
      name: tname("query_root"),
      description: None,
      fields: root_fields,
      interfaces: @sorted_map.SortedMap([]),
      directives: [],
    }),
  )
  // mutation_root (V2 風 CRUD、admin のみ)
  let mutation_type = build_mutation_root(meta, register)
  {
    types,
    query_type: tname("query_root"),
    mutation_type,
    subscription_type: None,
    namespaces: [],
  }
}

///|
/// モデル選択の共通引数 (where / order_by / limit / offset)
fn model_select_arguments(
  gql_type_name : String,
) -> @sorted_map.SortedMap[
  @graphql.Name,
  @schema.Namespaced[@schema.SInputField],
] {
  let args : @sorted_map.SortedMap[
    @graphql.Name,
    @schema.Namespaced[@schema.SInputField],
  ] = @sorted_map.SortedMap([])
  args[name("where")] = mk_input_field(
    "where",
    named_type("\{gql_type_name}_bool_exp", true),
    InputArg(ArgWhere),
  )
  args[name("order_by")] = mk_input_field(
    "order_by",
    list_of(named_type("\{gql_type_name}_order_by", false), true),
    InputArg(ArgOrderBy),
  )
  args[name("limit")] = mk_input_field(
    "limit",
    named_type("Int", true),
    InputArg(ArgLimit),
  )
  args[name("offset")] = mk_input_field(
    "offset",
    named_type("Int", true),
    InputArg(ArgOffset),
  )
  args
}

///|
/// モデルに権限が定義されているロールの map (role → NamespacedInfo)
fn model_permission_roles(
  meta : @metadata.Metadata,
  model_name : String,
) -> Map[String, @schema.NamespacedInfo] {
  let map : Map[String, @schema.NamespacedInfo] = Map([])
  match meta.model_permissions.get(model_name) {
    Some(mp) =>
      for p in mp.permissions {
        map[p.role] = ModelPermission(model_name)
      }
    None => ()
  }
  map
}

///|
/// フィールドのロール別可視性 (TypePermissions)。エントリが無い型は全ロール可
fn field_visibility(
  meta : @metadata.Metadata,
  type_name : String,
  field_name : String,
  data : @schema.SField,
) -> @schema.Namespaced[@schema.SField] {
  match meta.type_permissions.get(type_name) {
    None => @schema.allow_all_namespaced(data)
    Some(tp) => {
      let map : Map[String, @schema.NamespacedInfo] = Map([])
      for p in tp.permissions {
        if p.allowed_fields.contains(field_name) {
          map[p.role] = NoInfo
        }
      }
      @schema.conditional_namespaced(data, map)
    }
  }
}
