// lang-graphql/src/validation.rs + validation/selection_set.rs の移植

///|
/// GraphQL over HTTP のリクエスト
pub(all) struct Request {
  query : @graphql.ExecutableDocument
  operation_name : @graphql.Name?
  variables : Map[String, Json]
}

///|
/// リクエストを正規化する (エンジンの入口)
pub fn normalize_request(
  ns : NamespaceCtx,
  schema : Schema,
  request : Request,
) -> NOperation raise ValidationError {
  let fragments : Map[@graphql.Name, @graphql.FragmentDefinition] = Map([])
  // 匿名オペレーションはキー "" で管理する
  let operations : Map[String, @graphql.OperationDefinition] = Map([])
  for definition in request.query.items {
    match definition.item {
      Operation(operation) => {
        let key = match operation.name {
          Some(n) => n.item.as_str()
          None => ""
        }
        if operations.contains(key) {
          match operation.name {
            Some(operation_name) =>
              raise DuplicateOperationDefinitions(
                operation_name=operation_name.item.as_str(),
              )
            None => raise AnonymousOperationMustBeUnique
          }
        }
        operations[key] = operation
      }
      Fragment(fragment) => {
        if fragments.contains(fragment.name.item) {
          raise DuplicateFragmentDefinitions(
            fragment_name=fragment.name.item.as_str(),
          )
        }
        fragments[fragment.name.item] = fragment
      }
    }
  }

  // フラグメント循環チェック
  let visited_fragments : Map[String, Bool] = Map([])
  for name, fragment_definition in fragments {
    if !visited_fragments.contains(name.as_str()) {
      let fragment_path : Array[@graphql.Name] = []
      check_fragment_cycles(
        visited_fragments,
        fragment_path,
        fragments,
        fragment_definition.selection_set.item,
      )
    }
  }
  let operation = match request.operation_name {
    Some(operation_name) =>
      match operations.get(operation_name.as_str()) {
        Some(op) => op
        None => raise OperationNotFound(operation_name=operation_name.as_str())
      }
    None =>
      match operations.get("") {
        Some(op) =>
          if operations.length() == 1 {
            op
          } else {
            // 匿名 + 名前つきが混在: 匿名を選ぶ (V3 と同じく operations map から)
            op
          }
        None =>
          if operations.length() == 1 {
            let mut found : @graphql.OperationDefinition? = None
            for _, op in operations {
              found = Some(op)
            }
            found.unwrap()
          } else {
            raise AnonymousOperationNotFound
          }
      }
  }
  normalize_operation(ns, schema, fragments, operation, request.variables)
}

///|
fn check_fragment_cycles(
  all_referenced_fragments : Map[String, Bool],
  fragment_path : Array[@graphql.Name],
  fragments : Map[@graphql.Name, @graphql.FragmentDefinition],
  current_selection_set : @graphql.SelectionSet,
) -> Unit raise ValidationError {
  for selection in current_selection_set.items {
    match selection.item {
      Field(field) =>
        match field.selection_set {
          Some(field_selection_set) =>
            check_fragment_cycles(
              all_referenced_fragments,
              fragment_path,
              fragments,
              field_selection_set.item,
            )
          None => ()
        }
      FragmentSpread(spread) => {
        let fragment_name = spread.fragment_name.item
        if fragment_path.iter().any(n => n == fragment_name) {
          let path = fragment_path.map(n => n.as_str())
          path.push(fragment_name.as_str())
          raise CycleDetected(path)
        }
        fragment_path.push(fragment_name)
        all_referenced_fragments[fragment_name.as_str()] = true
        let fragment_definition = match fragments.get(fragment_name) {
          Some(f) => f
          None => raise UnknownFragment(fragment_name.as_str())
        }
        check_fragment_cycles(
          all_referenced_fragments,
          fragment_path,
          fragments,
          fragment_definition.selection_set.item,
        )
        ignore(fragment_path.pop())
      }
      InlineFragment(inline_fragment) =>
        check_fragment_cycles(
          all_referenced_fragments,
          fragment_path,
          fragments,
          inline_fragment.selection_set.item,
        )
    }
  }
}

///|
pub fn normalize_operation(
  ns : NamespaceCtx,
  schema : Schema,
  fragments : Map[@graphql.Name, @graphql.FragmentDefinition],
  operation : @graphql.OperationDefinition,
  variable_values : Map[String, Json],
) -> NOperation raise ValidationError {
  let variables = Variables::new(operation, variable_values, schema)
  let selection_set_type_name = match operation.ty {
    Query => schema.query_type
    Mutation =>
      match schema.mutation_type {
        Some(t) => t
        None => raise NoMutationsAreDefined
      }
    Subscription =>
      match schema.subscription_type {
        Some(t) => t
        None => raise NoSubscriptionsAreDefined
      }
  }
  let type_info = match schema.get_type(selection_set_type_name) {
    Some(t) => t
    None =>
      raise InternalTypeNotFound(type_name=selection_set_type_name.as_str())
  }
  let selection_set_type_info = match type_info.to_selectable_type() {
    Some(t) => t
    None => raise InternalSelectionRootIsNotObject
  }
  let normalized_selection_set = normalize_selection_set(
    ns,
    schema,
    fragments,
    variables,
    selection_set_type_info,
    operation.selection_set.item,
  )
  {
    ty: operation.ty,
    name: match operation.name {
      Some(n) => Some(n.item)
      None => None
    },
    selection_set: normalized_selection_set,
  }
}

///|
pub fn normalize_selection_set(
  ns : NamespaceCtx,
  schema : Schema,
  fragments : Map[@graphql.Name, @graphql.FragmentDefinition],
  variables : Variables,
  selection_type : SelectableType,
  selection_set : @graphql.SelectionSet,
) -> NSelectionSet raise ValidationError {
  normalize_selection_sets(ns, schema, fragments, variables, selection_type, [
    ([], [selection_set.items]),
  ])
}

///|
/// (field_path, selection sets) のグループ列から 1 つの正規化済みセレクションセットを作る
fn normalize_selection_sets(
  ns : NamespaceCtx,
  schema : Schema,
  fragments : Map[@graphql.Name, @graphql.FragmentDefinition],
  variables : Variables,
  selection_type : SelectableType,
  selection_set_groups : Array[
    (
      Array[@graphql.TypeName],
      Array[Array[@graphql.Spanning[@graphql.Selection]]],
    ),
  ],
) -> NSelectionSet raise ValidationError {
  let fields : Array[CollectedField] = []
  for group in selection_set_groups {
    let (path, selection_sets) = group
    for selection_set in selection_sets {
      collect_fields(
        ns, schema, fragments, path, selection_type, selection_set, fields,
      )
    }
  }
  // alias → (alias_type, field_path キー → フィールド群)
  let field_map : Map[
    @graphql.Name,
    (@graphql.GType, Map[String, Array[CollectedField]]),
  ] = Map([])
  for field in fields {
    let key = field_path_key(field.field_path)
    match field_map.get(field.calias) {
      Some((_, by_path)) =>
        match by_path.get(key) {
          Some(group) => group.push(field)
          None => by_path[key] = [field]
        }
      None =>
        field_map[field.calias] = (
          field.info.generic.field_type,
          Map::from_array([(key, [field])]),
        )
    }
  }
  let normalized_fields : Map[@graphql.Alias, NField] = Map([])
  for alias_name, entry in field_map {
    let (alias_type, typed_fields) = entry
    let nalias = @graphql.Alias(alias_name)
    let (field_calls, selection_set) = merge_fields(
      ns,
      schema,
      fragments,
      variables,
      selection_type.type_name,
      nalias,
      alias_type,
      typed_fields,
    )
    if !field_calls.is_empty() {
      normalized_fields[nalias] = NField::{
        nalias,
        field_calls,
        selection_set,
        type_container: alias_type,
      }
    }
  }
  let type_name_response : @graphql.TypeName? = if selection_type.possible_types.length() ==
    1 &&
    contains_type(selection_type.possible_types, selection_type.type_name) {
    Some(selection_type.type_name)
  } else {
    None
  }
  if normalized_fields.is_empty() {
    raise FieldSelectionSetIsEmpty
  }
  { fields: normalized_fields, type_name: type_name_response }
}

///|
fn merge_fields(
  ns : NamespaceCtx,
  schema : Schema,
  fragments : Map[@graphql.Name, @graphql.FragmentDefinition],
  variables : Variables,
  type_name : @graphql.TypeName,
  nalias : @graphql.Alias,
  alias_type : @graphql.GType,
  typed_fields : Map[String, Array[CollectedField]],
) -> (Map[String, FieldCall], NSelectionSet) raise ValidationError {
  let alias_type_info = match
    schema.get_type(underlying_type_name(alias_type)) {
    Some(t) => t
    None =>
      raise InternalTypeNotFound(
        type_name=underlying_type_name(alias_type).as_str(),
      )
  }
  let alias_selectable_type = alias_type_info.to_selectable_type()
  let alias_selection_sets : Array[
    (
      Array[@graphql.TypeName],
      Array[Array[@graphql.Spanning[@graphql.Selection]]],
    ),
  ] = []
  let field_calls : Map[String, FieldCall] = Map([])
  for reachability_key, group in typed_fields {
    let canonical_field = group[0]
    let arguments = normalize_arguments(
      ns,
      schema,
      variables,
      type_name,
      canonical_field.info.generic.name,
      canonical_field.info.generic.arguments,
      canonical_field.field.arguments,
    )
    let canonical_field_type = canonical_field.info.generic.field_type
    if canonical_field_type != alias_type {
      raise FieldsConflictDifferingTypes(
        nalias=nalias.0.as_str(),
        type1=gtype_display(alias_type),
        type2=gtype_display(canonical_field_type),
      )
    }
    let selection_sets : Array[Array[@graphql.Spanning[@graphql.Selection]]] = []
    match canonical_field.field.selection_set {
      Some(selection_set) => selection_sets.push(selection_set.item.items)
      None => ()
    }
    for idx in 1..<group.length() {
      let field = group[idx]
      if field.field.name.item != canonical_field.field.name.item {
        raise FieldsConflictDifferentFields(
          nalias=nalias.0.as_str(),
          field1=canonical_field.field.name.item.as_str(),
          field2=field.field.name.item.as_str(),
        )
      }
      let this_arguments = normalize_arguments(
        ns,
        schema,
        variables,
        type_name,
        field.info.generic.name,
        field.info.generic.arguments,
        field.field.arguments,
      )
      if !arguments_equal(arguments, this_arguments) {
        raise FieldsConflictDifferingArguments(nalias=nalias.0.as_str())
      }
      match field.field.selection_set {
        Some(selection_set) => selection_sets.push(selection_set.item.items)
        None => ()
      }
    }
    let field_call = FieldCall::{
      name: canonical_field.field.name.item,
      info: {
        generic: canonical_field.info.generic.info,
        namespaced: canonical_field.info.namespaced,
      },
      arguments,
    }
    if canonical_field.reachable {
      field_calls[reachability_key] = field_call
    }
    alias_selection_sets.push((canonical_field.field_path, selection_sets))
  }
  let normalized_selection_set : NSelectionSet = match alias_selectable_type {
    Some(selection_type) =>
      // V3 と同様、各グループの field_path をそのままネスト先へ伝播する
      normalize_selection_sets(
        ns, schema, fragments, variables, selection_type, alias_selection_sets,
      )
    None => { fields: Map([]), type_name: None }
  }
  (field_calls, normalized_selection_set)
}

///|
fn arguments_equal(
  a : Map[@graphql.Name, NInputField],
  b : Map[@graphql.Name, NInputField],
) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for k, va in a {
    match b.get(k) {
      Some(vb) => if va.value.as_json() != vb.value.as_json() { return false }
      None => return false
    }
  }
  true
}

///|
fn normalize_arguments(
  ns : NamespaceCtx,
  schema : Schema,
  variables : Variables,
  type_name : @graphql.TypeName,
  field_name : @graphql.Name,
  arguments_schema : @sorted_map.SortedMap[
    @graphql.Name,
    Namespaced[SInputField],
  ],
  arguments : @graphql.Spanning[Array[@graphql.Argument]]?,
) -> Map[@graphql.Name, NInputField] raise ValidationError {
  let arguments_map : Map[@graphql.Name, @graphql.Value] = Map([])
  match arguments {
    Some(args) =>
      for argument in args.item {
        let name = argument.item.key.item
        if arguments_map.contains(name) {
          raise DuplicateArguments(
            type_name=type_name.as_str(),
            field_name=field_name.as_str(),
            argument_name=name.as_str(),
          )
        }
        arguments_map[name] = argument.item.value.item
      }
    None => ()
  }
  let normalized_arguments : Map[@graphql.Name, NInputField] = Map([])
  let ctx : NormalizeCtx = { schema, ns, variables: Some(variables) }
  let const_ctx : NormalizeCtx = { schema, ns, variables: None }
  for entry in arguments_schema.iter() {
    let (name, info) = entry
    let argument_value = arguments_map.get(name)
    if arguments_map.contains(name) {
      arguments_map.remove(name)
    }
    match ns.get(info) {
      Some((argument_info, namespaced)) => {
        let argument_type = argument_info.field_type
        let argument_type_info = lookup_input_type(schema, argument_type)
        let normalized_field_value : NValue? = match
          (argument_value, argument_info.default_value) {
          (None, None) =>
            if argument_type.nullable {
              None
            } else {
              raise RequiredArgumentNotFound(
                type_name=type_name.as_str(),
                field_name=field_name.as_str(),
                argument_name=name.as_str(),
              )
            }
          (Some(argument_value), _) =>
            Some(
              normalize_input(
                ctx,
                VGql(argument_value),
                {
                  ty: argument_info.field_type,
                  default_value: argument_info.default_value,
                },
                argument_type_info,
              ),
            )
          (None, Some(default_value)) =>
            Some(
              normalize_input(
                const_ctx,
                VConst(default_value),
                {
                  ty: argument_info.field_type,
                  default_value: argument_info.default_value,
                },
                argument_type_info,
              ),
            )
        }
        match normalized_field_value {
          Some(v) =>
            normalized_arguments[name] = NInputField::{
              name,
              info: { generic: argument_info.info, namespaced },
              value: v,
            }
          None => ()
        }
      }
      None =>
        if argument_value is Some(_) {
          raise VArgumentNotFound(
            type_name=type_name.as_str(),
            field_name=field_name.as_str(),
            argument_name=name.as_str(),
          )
        }
    }
  }
  if arguments_map.is_empty() {
    normalized_arguments
  } else {
    let names = arguments_map.keys().map(n => n.as_str()).collect()
    raise ArgumentsNotFound(
      type_name=type_name.as_str(),
      field_name=field_name.as_str(),
      argument_names=names,
    )
  }
}
