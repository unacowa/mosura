// lang-graphql/src/validation/collect.rs の移植

///|
/// 選択可能な型 (Object / Interface / Union)
pub(all) struct SelectableType {
  type_name : @graphql.TypeName
  possible_types : Array[@graphql.TypeName]
  fields : @sorted_map.SortedMap[@graphql.Name, Namespaced[SField]]?
}

///|
pub(all) struct FieldInfo {
  generic : SField
  namespaced : NamespacedInfo
}

///|
fn SelectableType::lookup_field(
  self : SelectableType,
  ns : NamespaceCtx,
  field_name : @graphql.Name,
) -> FieldInfo raise ValidationError {
  let field_value = match self.fields {
    Some(m) =>
      match m.get(field_name) {
        Some(f) => f
        None =>
          raise NoFieldOnType(
            type_name=self.type_name.as_str(),
            field_name=field_name.as_str(),
          )
      }
    None =>
      raise NoFieldOnType(
        type_name=self.type_name.as_str(),
        field_name=field_name.as_str(),
      )
  }
  match ns.get(field_value) {
    Some((generic, namespaced)) => { generic, namespaced }
    None =>
      raise NoFieldOnType(
        type_name=self.type_name.as_str(),
        field_name=field_name.as_str(),
      )
  }
}

///|
pub fn TypeInfo::to_selectable_type(self : TypeInfo) -> SelectableType? {
  match self {
    Object(object) =>
      Some({
        type_name: object.name,
        fields: Some(object.fields),
        possible_types: [object.name],
      })
    Interface(interface) =>
      Some({
        type_name: interface.name,
        fields: Some(interface.fields),
        possible_types: interface.implemented_by.keys().collect(),
      })
    Union(union) =>
      Some({
        type_name: union.name,
        fields: Some(union.fields),
        possible_types: union.members.keys().collect(),
      })
    Scalar(_) | Enum(_) | InputObject(_) => None
  }
}

///|
fn get_type_info(
  schema : Schema,
  type_name : @graphql.TypeName,
) -> TypeInfo raise ValidationError {
  match schema.get_type(type_name) {
    Some(t) => t
    None => raise UnknownType(type_name.as_str())
  }
}

///|
pub(all) struct CollectedField {
  calias : @graphql.Name
  info : FieldInfo
  field_path : Array[@graphql.TypeName]
  reachable : Bool
  field : @graphql.Field
}

///|
fn contains_type(arr : Array[@graphql.TypeName], t : @graphql.TypeName) -> Bool {
  arr.iter().any(x => x == t)
}

///|
fn intersect_types(
  a : Array[@graphql.TypeName],
  b : Array[@graphql.TypeName],
) -> Array[@graphql.TypeName] {
  a.filter(x => contains_type(b, x))
}

///|
pub fn collect_fields(
  ns : NamespaceCtx,
  schema : Schema,
  fragments : Map[@graphql.Name, @graphql.FragmentDefinition],
  field_path : Array[@graphql.TypeName],
  selection_type : SelectableType,
  selection_set : Array[@graphql.Spanning[@graphql.Selection]],
  fields : Array[CollectedField],
) -> Unit raise ValidationError {
  collect_fields_internal(
    ns,
    schema,
    fragments,
    field_path,
    selection_type,
    selection_type.possible_types,
    None,
    selection_set,
    fields,
  )
}

///|
fn collect_fields_from_fragment(
  ns : NamespaceCtx,
  schema : Schema,
  fragments : Map[@graphql.Name, @graphql.FragmentDefinition],
  field_path : Array[@graphql.TypeName],
  selection_type : SelectableType,
  coerce_as : SelectableType?,
  selection_set_reachability : Array[@graphql.TypeName],
  fragment_selection_type : SelectableType,
  fragment_selection_set : @graphql.SelectionSet,
  fields : Array[CollectedField],
) -> Unit raise ValidationError {
  let common_types = intersect_types(
    selection_type.possible_types,
    fragment_selection_type.possible_types,
  )
  if common_types.is_empty() {
    raise FragmentCannotBeSpread(
      selection_type=selection_type.type_name.as_str(),
      fragment_type=fragment_selection_type.type_name.as_str(),
    )
  }
  let fragment_reachability = intersect_types(
    selection_set_reachability, common_types,
  )
  let fragment_field_path = field_path.copy()
  let fragment_to_be_coerced_as : SelectableType? = if fragment_selection_type.type_name ==
    selection_type.type_name {
    coerce_as
  } else if contains_type(
      fragment_selection_type.possible_types,
      selection_type.type_name,
    ) {
    Some(
      match coerce_as {
        Some(c) => c
        None => selection_type
      },
    )
  } else {
    fragment_field_path.push(fragment_selection_type.type_name)
    None
  }
  collect_fields_internal(
    ns,
    schema,
    fragments,
    fragment_field_path,
    fragment_selection_type,
    fragment_reachability,
    fragment_to_be_coerced_as,
    fragment_selection_set.items,
    fields,
  )
}

///|
fn collect_fields_internal(
  ns : NamespaceCtx,
  schema : Schema,
  fragments : Map[@graphql.Name, @graphql.FragmentDefinition],
  field_path : Array[@graphql.TypeName],
  selection_type : SelectableType,
  selection_set_reachability : Array[@graphql.TypeName],
  selection_sub_type : SelectableType?,
  selection_set : Array[@graphql.Spanning[@graphql.Selection]],
  fields : Array[CollectedField],
) -> Unit raise ValidationError {
  for selection in selection_set {
    match selection.item {
      Field(field) => {
        let field_info = selection_type.lookup_field(ns, field.name.item)
        let alias_name = match field.field_alias {
          Some(a) => a.item.0
          None => field.name.item
        }
        // サブタイプがある場合はそちらの定義を使う
        let refined_field_info = match selection_sub_type {
          Some(sub_type) =>
            sub_type.lookup_field(ns, field.name.item) catch {
              _ =>
                raise InternalNoFieldOnSubtype(
                  type_name=sub_type.type_name.as_str(),
                  sub_type_name=selection_type.type_name.as_str(),
                  field_name=field.name.item.as_str(),
                )
            }
          None => field_info
        }
        fields.push(CollectedField::{
          calias: alias_name,
          field_path: field_path.copy(),
          info: refined_field_info,
          field,
          reachable: !selection_set_reachability.is_empty(),
        })
      }
      FragmentSpread(spread) => {
        let fragment_name = spread.fragment_name.item
        let fragment_definition = match fragments.get(fragment_name) {
          Some(f) => f
          None => raise UnknownFragment(fragment_name.as_str())
        }
        let fragment_type_name = fragment_definition.type_condition.item.on.item
        let fragment_type_info = get_type_info(schema, fragment_type_name)
        let fragment_selection_type = match
          fragment_type_info.to_selectable_type() {
          Some(t) => t
          None =>
            raise FragmentOnNonCompositeType(
              fragment_name=Some(fragment_name.as_str()),
              type_name=selection_type.type_name.as_str(),
            )
        }
        collect_fields_from_fragment(
          ns,
          schema,
          fragments,
          field_path,
          selection_type,
          selection_sub_type,
          selection_set_reachability,
          fragment_selection_type,
          fragment_definition.selection_set.item,
          fields,
        )
      }
      InlineFragment(spread) => {
        let fragment_selection_type : SelectableType? = match
          spread.type_condition {
          Some(type_condition) => {
            let fragment_type_name = type_condition.item.on.item
            let fragment_type_info = get_type_info(schema, fragment_type_name)
            match fragment_type_info.to_selectable_type() {
              Some(t) => Some(t)
              None =>
                raise FragmentOnNonCompositeType(
                  fragment_name=None,
                  type_name=selection_type.type_name.as_str(),
                )
            }
          }
          None => None
        }
        collect_fields_from_fragment(
          ns,
          schema,
          fragments,
          field_path,
          selection_type,
          selection_sub_type,
          selection_set_reachability,
          match fragment_selection_type {
            Some(t) => t
            None => selection_type
          },
          spread.selection_set.item,
          fields,
        )
      }
    }
  }
}
