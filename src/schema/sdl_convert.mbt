// lang-graphql/src/schema/build.rs の移植 (SDL 定義 → TypeInfo 変換と introspection 型の登録)

///|
pub suberror SchemaBuildError {
  InternalParseError(String)
} derive(Debug)

///|
pub fn SchemaBuildError::display(self : SchemaBuildError) -> String {
  match self {
    InternalParseError(e) =>
      "internal error when parsing introspection schema : \{e}"
  }
}

///|
fn opt_description(d : @graphql.Spanning[String]?) -> String? {
  match d {
    Some(s) => Some(s.item)
    None => None
  }
}

///|
fn convert_directives(
  const_directives : Array[@graphql.Spanning[@graphql.ConstDirective]],
) -> Array[SDirective] {
  let directives = []
  for directive in const_directives {
    let arguments : @sorted_map.SortedMap[@graphql.Name, @graphql.ConstValue] = @sorted_map.SortedMap([],
    )
    match directive.item.arguments {
      Some(args) =>
        for argument in args.item {
          arguments[argument.item.key.item] = argument.item.value.item
        }
      None => ()
    }
    directives.push(SDirective::{ name: directive.item.name.item, arguments })
  }
  directives
}

///|
fn convert_input_value_definition(
  definition : @graphql.InputValueDefinition,
) -> SInputField {
  {
    name: definition.name.item,
    description: opt_description(definition.description),
    info: Introspection,
    field_type: definition.ty.item,
    default_value: match definition.default_value {
      Some(dv) => Some(dv.item)
      None => None
    },
    deprecation_status: NotDeprecated,
  }
}

///|
fn convert_field_definition(definition : @graphql.FieldDefinition) -> SField {
  let arguments : @sorted_map.SortedMap[@graphql.Name, Namespaced[SInputField]] = @sorted_map.SortedMap([],
  )
  for field_definition in definition.arguments {
    let argument_name = field_definition.item.name.item
    arguments[argument_name] = allow_all_namespaced(
      convert_input_value_definition(field_definition.item),
    )
  }
  {
    name: definition.name.item,
    description: opt_description(definition.description),
    info: Introspection,
    field_type: definition.ty.item,
    arguments,
    deprecation_status: NotDeprecated,
  }
}

///|
fn convert_fields(
  fields : Array[@graphql.Spanning[@graphql.FieldDefinition]],
) -> @sorted_map.SortedMap[@graphql.Name, Namespaced[SField]] {
  let m : @sorted_map.SortedMap[@graphql.Name, Namespaced[SField]] = @sorted_map.SortedMap([],
  )
  for field in fields {
    m[field.item.name.item] = allow_all_namespaced(
      convert_field_definition(field.item),
    )
  }
  m
}

///|
/// SDL の型定義を TypeInfo に変換する
pub fn convert_type_definition(
  definition : @graphql.TypeDefinition,
) -> TypeInfo {
  match definition {
    Scalar(d) =>
      TypeInfo::Scalar({
        name: @graphql.TypeName(d.name.item),
        description: opt_description(d.description),
        directives: [],
      })
    Object(d) => {
      let fields = convert_fields(d.fields)
      let tn = build_typename_field()
      fields[tn.data.name] = tn
      let interfaces : @sorted_map.SortedMap[
        @graphql.TypeName,
        Namespaced[Unit],
      ] = @sorted_map.SortedMap([])
      for i in d.implements {
        interfaces[@graphql.TypeName(i.item)] = allow_all_namespaced(())
      }
      TypeInfo::Object({
        name: @graphql.TypeName(d.name.item),
        description: opt_description(d.description),
        fields,
        interfaces,
        directives: convert_directives(d.directives),
      })
    }
    Interface(d) => {
      let fields = convert_fields(d.fields)
      let tn = build_typename_field()
      fields[tn.data.name] = tn
      let interfaces : @sorted_map.SortedMap[
        @graphql.TypeName,
        Namespaced[Unit],
      ] = @sorted_map.SortedMap([])
      for i in d.implements {
        interfaces[@graphql.TypeName(i.item)] = allow_all_namespaced(())
      }
      TypeInfo::Interface({
        name: @graphql.TypeName(d.name.item),
        description: opt_description(d.description),
        fields,
        interfaces,
        implemented_by: @sorted_map.SortedMap([]),
        directives: convert_directives(d.directives),
      })
    }
    Union(d) => {
      let members : @sorted_map.SortedMap[@graphql.TypeName, Namespaced[Unit]] = @sorted_map.SortedMap([],
      )
      for m in d.members {
        members[@graphql.TypeName(m.item)] = allow_all_namespaced(())
      }
      let fields : @sorted_map.SortedMap[@graphql.Name, Namespaced[SField]] = @sorted_map.SortedMap([],
      )
      let tn = build_typename_field()
      fields[tn.data.name] = tn
      TypeInfo::Union({
        name: @graphql.TypeName(d.name.item),
        description: opt_description(d.description),
        fields,
        members,
        directives: convert_directives(d.directives),
      })
    }
    Enum(d) => {
      let values : @sorted_map.SortedMap[@graphql.Name, Namespaced[SEnumValue]] = @sorted_map.SortedMap([],
      )
      for enum_value_definition in d.values {
        let ev = enum_value_definition.item
        values[ev.value.item] = allow_all_namespaced(SEnumValue::{
          value: ev.value.item,
          description: opt_description(ev.description),
          deprecation_status: NotDeprecated,
          info: Introspection,
        })
      }
      TypeInfo::Enum({
        name: @graphql.TypeName(d.name.item),
        description: opt_description(d.description),
        values,
        directives: convert_directives(d.directives),
      })
    }
    InputObject(d) => {
      let fields : @sorted_map.SortedMap[@graphql.Name, Namespaced[SInputField]] = @sorted_map.SortedMap([],
      )
      for f in d.fields {
        fields[f.item.name.item] = allow_all_namespaced(
          convert_input_value_definition(f.item),
        )
      }
      TypeInfo::InputObject({
        name: @graphql.TypeName(d.name.item),
        description: opt_description(d.description),
        fields,
        directives: convert_directives(d.directives),
      })
    }
  }
}

///|
/// introspection の型群と query root 用フィールド (__schema / __type) を返す
pub fn introspection_parts() -> (
  Array[TypeInfo],
  @sorted_map.SortedMap[@graphql.Name, Namespaced[SField]],
) raise SchemaBuildError {
  let sdl = introspection_sdl()
  let parser = @graphql.Parser::new(@utf8.encode(sdl))
  let document = parser.parse_schema_document() catch {
    @graphql.ParseErr(p) => raise InternalParseError(p.item.display())
  }
  let types : Array[TypeInfo] = []
  let mut root_fields : @sorted_map.SortedMap[@graphql.Name, Namespaced[SField]] = @sorted_map.SortedMap([],
  )
  for definition in document.definitions {
    match definition.item {
      Type(type_definition) => {
        let normalized = convert_type_definition(type_definition)
        if normalized.type_name().as_str() == "Query" {
          match normalized {
            Object(query_root) => root_fields = query_root.fields
            _ => ()
          }
        } else {
          types.push(normalized)
        }
      }
      Schema(_) | Directive(_) => ()
    }
  }
  (types, root_fields)
}

///|
/// 組み込みスカラー型
pub fn builtin_scalars() -> Array[TypeInfo] {
  ["Int", "Float", "Boolean", "String", "ID"].map(name => {
    TypeInfo::Scalar({
      name: @graphql.TypeName(@graphql.Name::new_unchecked(name)),
      description: None,
      directives: [],
    })
  })
}
