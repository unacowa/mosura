// mutation_root の生成 (Hasura V2 風の自動 CRUD)
// - insert_<model>(objects: [<type>_insert_input!]!) : <type>_mutation_response!
// - update_<model>_by_pk(pk_columns: ..., _set: <type>_set_input!) : <type>
// - delete_<model>_by_pk(<pk args>) : <type>
// MVP ではミューテーションは admin のみ (ロール別 insert/update/delete 権限は将来対応)

///|
fn nullable_variant(t : @graphql.GType) -> @graphql.GType {
  { base: t.base, nullable: true }
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

    // <type>_insert_input
    let insert_input_fields : @sorted_map.SortedMap[
      @graphql.Name,
      @schema.Namespaced[@schema.SInputField],
    ] = @sorted_map.SortedMap([])
    for f in ot.fields {
      insert_input_fields[name(f.name)] = mk_input_field(
        f.name,
        nullable_variant(f.field_type),
        InputArg(MutationInputField(f.name)),
      )
    }
    register(
      @schema.TypeInfo::InputObject({
        name: tname("\{gql_name}_insert_input"),
        description: None,
        fields: insert_input_fields,
        directives: [],
      }),
    )

    // <type>_set_input (更新可能フィールド: 全フィールド nullable)
    register(
      @schema.TypeInfo::InputObject({
        name: tname("\{gql_name}_set_input"),
        description: None,
        fields: insert_input_fields,
        directives: [],
      }),
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
    // admin のみ (空 conditional)
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
      Map([]),
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
        Map([]),
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
        Map([]),
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
