// mutation_root の生成 (Hasura V2 風の自動 CRUD)
// - insert_<model>(objects: [<type>_insert_input!]!) : <type>_mutation_response!
// - update_<model>_by_pk(pk_columns: ..., _set: <type>_set_input!) : <type>
// - delete_<model>_by_pk(<pk args>) : <type>
// admin は常に全ミューテーション可。他ロールは ModelPermissions の
// insert/update/delete セクションがある場合のみ生成される (M6)

///|
fn nullable_variant(t : @graphql.GType) -> @graphql.GType {
  { base: t.base, nullable: true }
}

///|
priv enum MutationPermKind {
  PermInsert
  PermUpdate
  PermDelete
}

///|
/// 指定ミューテーションを許可されたロールの一覧 (admin は AllowAll 側で処理)
fn mutation_permission_roles(
  meta : @metadata.Metadata,
  model_name : String,
  kind : MutationPermKind,
) -> Map[String, @schema.NamespacedInfo] {
  let map : Map[String, @schema.NamespacedInfo] = Map([])
  match meta.model_permissions.get(model_name) {
    Some(mp) =>
      for p in mp.permissions {
        let allowed = match kind {
          PermInsert => p.insert is Some(_)
          PermUpdate => p.update is Some(_)
          PermDelete => p.delete is Some(_)
        }
        if allowed {
          map[p.role] = ModelPermission(model_name)
        }
      }
    None => ()
  }
  map
}

///|
/// <type>_insert_input / <type>_set_input の入力オブジェクト型を作る
/// (全フィールド nullable。可視性はロールの columns / presets に従う)
fn mutation_input_object(
  meta : @metadata.Metadata,
  model_name : String,
  ot : @metadata.ObjectTypeDef,
  kind : MutationPermKind,
  type_name : String,
) -> @schema.TypeInfo {
  let fields : @sorted_map.SortedMap[
    @graphql.Name,
    @schema.Namespaced[@schema.SInputField],
  ] = @sorted_map.SortedMap([])
  for f in ot.fields {
    let data : @schema.SInputField = {
      name: name(f.name),
      description: None,
      info: InputArg(MutationInputField(f.name)),
      field_type: nullable_variant(f.field_type),
      default_value: None,
      deprecation_status: NotDeprecated,
    }
    fields[name(f.name)] = @schema.conditional_namespaced(
      data,
      mutation_input_field_roles(meta, model_name, kind, f.name),
    )
  }
  @schema.TypeInfo::InputObject({
    name: tname(type_name),
    description: None,
    fields,
    directives: [],
  })
}

///|
/// insert/update 入力フィールドのロール別可視性
/// (判定ルールの実体は @metadata の allows_column — ir の防御的検査と共有)
fn mutation_input_field_roles(
  meta : @metadata.Metadata,
  model_name : String,
  kind : MutationPermKind,
  field_name : String,
) -> Map[String, @schema.NamespacedInfo] {
  let map : Map[String, @schema.NamespacedInfo] = Map([])
  match meta.model_permissions.get(model_name) {
    Some(mp) =>
      for p in mp.permissions {
        let visible = match kind {
          PermInsert =>
            match p.insert {
              Some(ins) => ins.allows_column(field_name)
              None => false
            }
          PermUpdate =>
            match p.update {
              Some(upd) => upd.allows_column(field_name)
              None => false
            }
          PermDelete => false
        }
        if visible {
          map[p.role] = ModelPermission(model_name)
        }
      }
    None => ()
  }
  map
}

///|
/// mutation_root と関連入力型を登録し、mutation_root の型名を返す。
/// モデルが無い場合は None
pub fn build_mutation_root(
  meta : @metadata.Metadata,
  register : (@schema.TypeInfo) -> Unit,
) -> @graphql.TypeName? {
  if meta.models.is_empty() {
    return None
  }
  let root_fields : @sorted_map.SortedMap[
    @graphql.Name,
    @schema.Namespaced[@schema.SField],
  ] = @sorted_map.SortedMap([])
  let mut has_any = false
  for model_name, model in meta.models {
    let ot = meta.object_types.get(model.object_type).unwrap()
    let gql_name = ot.graphql_type_name

    // <type>_insert_input / <type>_set_input (全フィールド nullable。
    // 可視性はロールの insert/update の columns / presets に従う)
    register(
      mutation_input_object(
        meta,
        model_name,
        ot,
        PermInsert,
        "\{gql_name}_insert_input",
      ),
    )
    register(
      mutation_input_object(
        meta,
        model_name,
        ot,
        PermUpdate,
        "\{gql_name}_set_input",
      ),
    )

    // <type>_mutation_response
    let response_fields : @sorted_map.SortedMap[
      @graphql.Name,
      @schema.Namespaced[@schema.SField],
    ] = @sorted_map.SortedMap([])
    response_fields[name("affected_rows")] = mk_field(
      "affected_rows",
      named_type("Int", false),
      AffectedRows,
      @sorted_map.SortedMap([]),
    )
    response_fields[name("returning")] = mk_field(
      "returning",
      list_of(named_type(gql_name, false), false),
      ReturningRows(model_name),
      @sorted_map.SortedMap([]),
    )
    let tn_field = @schema.build_typename_field()
    response_fields[tn_field.data.name] = tn_field
    register(
      @schema.TypeInfo::Object({
        name: tname("\{gql_name}_mutation_response"),
        description: None,
        fields: response_fields,
        interfaces: @sorted_map.SortedMap([]),
        directives: [],
      }),
    )

    // insert_<model>
    let insert_args : @sorted_map.SortedMap[
      @graphql.Name,
      @schema.Namespaced[@schema.SInputField],
    ] = @sorted_map.SortedMap([])
    insert_args[name("objects")] = mk_input_field(
      "objects",
      list_of(named_type("\{gql_name}_insert_input", false), false),
      InputArg(MutationInputField("objects")),
    )
    let insert_data : @schema.SField = {
      name: name("insert_\{model_name}"),
      description: None,
      info: ModelInsert(model_name),
      field_type: named_type("\{gql_name}_mutation_response", true),
      arguments: insert_args,
      deprecation_status: NotDeprecated,
    }
    root_fields[name("insert_\{model_name}")] = @schema.conditional_namespaced(
      insert_data,
      mutation_permission_roles(meta, model_name, PermInsert),
    )
    has_any = true

    // update / delete by pk (主キーがあるモデルのみ)
    if !model.primary_key.is_empty() {
      let pk_args : @sorted_map.SortedMap[
        @graphql.Name,
        @schema.Namespaced[@schema.SInputField],
      ] = @sorted_map.SortedMap([])
      for pk in model.primary_key {
        let f = ot.fields.iter().find_first(x => x.name == pk).unwrap()
        pk_args[name(pk)] = mk_input_field(
          pk,
          named_type(scalar_name(f.field_type), false),
          InputArg(ArgPkColumn(pk)),
        )
      }
      // update_<model>_by_pk(<pk args>, _set: ...)
      let update_args : @sorted_map.SortedMap[
        @graphql.Name,
        @schema.Namespaced[@schema.SInputField],
      ] = @sorted_map.SortedMap([])
      for entry in pk_args.iter() {
        let (k, v) = entry
        update_args[k] = v
      }
      update_args[name("_set")] = mk_input_field(
        "_set",
        named_type("\{gql_name}_set_input", false),
        InputArg(MutationInputField("_set")),
      )
      let update_data : @schema.SField = {
        name: name("update_\{model_name}_by_pk"),
        description: None,
        info: ModelUpdateByPk(model_name),
        field_type: named_type(gql_name, true),
        arguments: update_args,
        deprecation_status: NotDeprecated,
      }
      root_fields[name("update_\{model_name}_by_pk")] = @schema.conditional_namespaced(
        update_data,
        mutation_permission_roles(meta, model_name, PermUpdate),
      )
      let delete_data : @schema.SField = {
        name: name("delete_\{model_name}_by_pk"),
        description: None,
        info: ModelDeleteByPk(model_name),
        field_type: named_type(gql_name, true),
        arguments: pk_args,
        deprecation_status: NotDeprecated,
      }
      root_fields[name("delete_\{model_name}_by_pk")] = @schema.conditional_namespaced(
        delete_data,
        mutation_permission_roles(meta, model_name, PermDelete),
      )
    }
  }
  if !has_any {
    return None
  }
  let tn_field = @schema.build_typename_field()
  root_fields[tn_field.data.name] = tn_field
  register(
    @schema.TypeInfo::Object({
      name: tname("mutation_root"),
      description: None,
      fields: root_fields,
      interfaces: @sorted_map.SortedMap([]),
      directives: [],
    }),
  )
  Some(tname("mutation_root"))
}
