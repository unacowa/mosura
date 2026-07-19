// lang-graphql/src/introspection.rs の移植

///|
pub suberror IntrospectionError {
  IntrospectionInternal(String)
}

///|
fn json_opt_string(s : String?) -> Json {
  match s {
    Some(v) => Json::string(v)
    None => Json::null()
  }
}

///|
/// __schema フィールドの応答
pub fn schema_type(
  schema : Schema,
  ns : NamespaceCtx,
  selection_set : NSelectionSet,
) -> Json raise {
  let obj = selection_set.as_object_selection_set((
    _type_name,
    field,
    field_call,
  ) => {
    match field_call.name.as_str() {
      "types" => {
        // 到達可能な型のみ公開する
        let accessible_types : Map[String, Bool] = Map([])
        collect_accessible_types(ns, schema, accessible_types)
        let publishable_types : Array[TypeInfo] = []
        for entry in schema.types.iter() {
          let (name, ti) = entry
          if accessible_types.contains(name.as_str()) ||
            is_inbuilt_type(ti) ||
            is_schema_type(ti) {
            publishable_types.push(ti)
          }
        }
        // SortedMap の走査は型名順なのでソート済み
        let arr = []
        for ti in publishable_types {
          arr.push(
            Json::object(named_type(schema, ns, ti, field.selection_set)),
          )
        }
        Json::array(arr)
      }
      "queryType" =>
        Json::object(
          named_type_lookup_internal(
            schema,
            ns,
            schema.query_type,
            field.selection_set,
          ),
        )
      "mutationType" =>
        match schema.mutation_type {
          Some(type_name) =>
            Json::object(
              named_type_lookup_internal(
                schema,
                ns,
                type_name,
                field.selection_set,
              ),
            )
          None => Json::null()
        }
      "subscriptionType" =>
        match schema.subscription_type {
          Some(type_name) =>
            Json::object(
              named_type_lookup_internal(
                schema,
                ns,
                type_name,
                field.selection_set,
              ),
            )
          None => Json::null()
        }
      "directives" => Json::array([])
      _ => Json::null()
    }
  })
  Json::object(obj)
}

///|
/// __type(name:) フィールドの応答
pub fn type_lookup(
  schema : Schema,
  ns : NamespaceCtx,
  type_name : @graphql.TypeName,
  selection_set : NSelectionSet,
) -> Json raise {
  match schema.get_type(type_name) {
    Some(ti) => Json::object(named_type(schema, ns, ti, selection_set))
    None => Json::null()
  }
}

///|
pub fn named_type(
  schema : Schema,
  ns : NamespaceCtx,
  type_ : TypeInfo,
  selection_set : NSelectionSet,
) -> Map[String, Json] raise {
  match type_ {
    Scalar(scalar) => scalar_type(scalar, selection_set)
    Enum(enum_) => enum_type(ns, enum_, selection_set)
    Object(object) => object_type(ns, schema, object, selection_set)
    Interface(interface) => interface_type(ns, schema, interface, selection_set)
    Union(union) => union_type(ns, schema, union, selection_set)
    InputObject(input_object) =>
      input_object_type(ns, schema, input_object, selection_set)
  }
}

///|
fn named_type_lookup_internal(
  schema : Schema,
  ns : NamespaceCtx,
  type_name : @graphql.TypeName,
  selection_set : NSelectionSet,
) -> Map[String, Json] raise {
  let type_info = match schema.get_type(type_name) {
    Some(t) => t
    None =>
      raise IntrospectionInternal(
        "expected type not found in schema: \{type_name.as_str()}",
      )
  }
  named_type(schema, ns, type_info, selection_set)
}

///|
fn scalar_type(
  scalar : SScalar,
  selection_set : NSelectionSet,
) -> Map[String, Json] raise {
  selection_set.as_object_selection_set((_t, _f, field_call) => {
    match field_call.name.as_str() {
      "kind" => Json::string("SCALAR")
      "name" => Json::string(scalar.name.as_str())
      "description" => json_opt_string(scalar.description)
      _ => Json::null()
    }
  })
}

///|
fn include_deprecated_arg(field_call : FieldCall) -> Bool raise {
  field_call.expected_argument(
    @graphql.Name::new_unchecked("includeDeprecated"),
  ).value.as_boolean()
}

///|
fn enum_type(
  ns : NamespaceCtx,
  enum_ : SEnum,
  selection_set : NSelectionSet,
) -> Map[String, Json] raise {
  selection_set.as_object_selection_set((_t, field, field_call) => {
    match field_call.name.as_str() {
      "kind" => Json::string("ENUM")
      "name" => Json::string(enum_.name.as_str())
      "description" => json_opt_string(enum_.description)
      "enumValues" => {
        let include_deprecated = include_deprecated_arg(field_call)
        let allowed_values : Array[SEnumValue] = []
        for entry in enum_.values.iter() {
          let (_, namespaced_value) = entry
          match ns.get(namespaced_value) {
            Some((v, _)) =>
              if !v.deprecation_status.is_deprecated() || include_deprecated {
                allowed_values.push(v)
              }
            None => ()
          }
        }
        // SortedMap 走査のため値名順
        let arr = []
        for v in allowed_values {
          arr.push(Json::object(enum_value_response(v, field.selection_set)))
        }
        Json::array(arr)
      }
      _ => Json::null()
    }
  })
}

///|
fn collect_allowed_fields(
  ns : NamespaceCtx,
  fields : @sorted_map.SortedMap[@graphql.Name, Namespaced[SField]],
  include_deprecated : Bool,
) -> Array[SField] {
  let allowed : Array[SField] = []
  for entry in fields.iter() {
    let (_, namespaced_field) = entry
    match ns.get(namespaced_field) {
      Some((f, _)) =>
        if (!f.deprecation_status.is_deprecated() || include_deprecated) &&
          !f.name.as_str().has_prefix("__") {
          allowed.push(f)
        }
      None => ()
    }
  }
  allowed
}

///|
fn dummy_no_fields_accessible() -> SField {
  {
    name: @graphql.Name::new_unchecked("_no_fields_accessible"),
    description: None,
    info: Introspection,
    field_type: {
      base: Named(@graphql.TypeName(@graphql.Name::new_unchecked("String"))),
      nullable: true,
    },
    arguments: @sorted_map.SortedMap([]),
    deprecation_status: NotDeprecated,
  }
}

///|
fn object_type(
  ns : NamespaceCtx,
  schema : Schema,
  object : SObject,
  selection_set : NSelectionSet,
) -> Map[String, Json] raise {
  selection_set.as_object_selection_set((_t, field, field_call) => {
    match field_call.name.as_str() {
      "kind" => Json::string("OBJECT")
      "name" => Json::string(object.name.as_str())
      "description" => json_opt_string(object.description)
      "fields" => {
        let include_deprecated = include_deprecated_arg(field_call)
        let allowed_fields = collect_allowed_fields(
          ns,
          object.fields,
          include_deprecated,
        )
        if allowed_fields.is_empty() {
          allowed_fields.push(dummy_no_fields_accessible())
        }
        let arr = []
        for f in allowed_fields {
          arr.push(
            Json::object(object_field(ns, schema, f, field.selection_set)),
          )
        }
        Json::array(arr)
      }
      "interfaces" => {
        let interfaces : Array[@graphql.TypeName] = []
        for entry in object.interfaces.iter() {
          let (name, namespaced) = entry
          if ns.get(namespaced) is Some(_) {
            interfaces.push(name)
          }
        }
        let arr = []
        for i in interfaces {
          arr.push(
            Json::object(
              named_type_lookup_internal(schema, ns, i, field.selection_set),
            ),
          )
        }
        Json::array(arr)
      }
      _ => Json::null()
    }
  })
}

///|
fn interface_type(
  ns : NamespaceCtx,
  schema : Schema,
  interface : SInterface,
  selection_set : NSelectionSet,
) -> Map[String, Json] raise {
  selection_set.as_object_selection_set((_t, field, field_call) => {
    match field_call.name.as_str() {
      "kind" => Json::string("INTERFACE")
      "name" => Json::string(interface.name.as_str())
      "description" => json_opt_string(interface.description)
      "fields" => {
        let include_deprecated = include_deprecated_arg(field_call)
        let allowed_fields = collect_allowed_fields(
          ns,
          interface.fields,
          include_deprecated,
        )
        let arr = []
        for f in allowed_fields {
          arr.push(
            Json::object(object_field(ns, schema, f, field.selection_set)),
          )
        }
        Json::array(arr)
      }
      "interfaces" => {
        let arr = []
        for entry in interface.interfaces.iter() {
          let (name, namespaced) = entry
          if ns.get(namespaced) is Some(_) {
            arr.push(
              Json::object(
                named_type_lookup_internal(
                  schema,
                  ns,
                  name,
                  field.selection_set,
                ),
              ),
            )
          }
        }
        Json::array(arr)
      }
      "possibleTypes" => {
        let arr = []
        for entry in interface.implemented_by.iter() {
          let (name, namespaced) = entry
          if ns.get(namespaced) is Some(_) {
            arr.push(
              Json::object(
                named_type_lookup_internal(
                  schema,
                  ns,
                  name,
                  field.selection_set,
                ),
              ),
            )
          }
        }
        Json::array(arr)
      }
      _ => Json::null()
    }
  })
}

///|
fn union_type(
  ns : NamespaceCtx,
  schema : Schema,
  union : SUnion,
  selection_set : NSelectionSet,
) -> Map[String, Json] raise {
  selection_set.as_object_selection_set((_t, field, field_call) => {
    match field_call.name.as_str() {
      "kind" => Json::string("UNION")
      "name" => Json::string(union.name.as_str())
      "description" => json_opt_string(union.description)
      "possibleTypes" => {
        let arr = []
        for entry in union.members.iter() {
          let (name, namespaced) = entry
          if ns.get(namespaced) is Some(_) {
            arr.push(
              Json::object(
                named_type_lookup_internal(
                  schema,
                  ns,
                  name,
                  field.selection_set,
                ),
              ),
            )
          }
        }
        Json::array(arr)
      }
      _ => Json::null()
    }
  })
}

///|
fn input_object_type(
  ns : NamespaceCtx,
  schema : Schema,
  input_object : SInputObject,
  selection_set : NSelectionSet,
) -> Map[String, Json] raise {
  selection_set.as_object_selection_set((_t, field, field_call) => {
    match field_call.name.as_str() {
      "kind" => Json::string("INPUT_OBJECT")
      "name" => Json::string(input_object.name.as_str())
      "description" => json_opt_string(input_object.description)
      "inputFields" => {
        let include_deprecated = include_deprecated_arg(field_call)
        let allowed_fields : Array[SInputField] = []
        for entry in input_object.fields.iter() {
          let (_, namespaced_field) = entry
          match ns.get(namespaced_field) {
            Some((f, _)) =>
              if !f.deprecation_status.is_deprecated() || include_deprecated {
                allowed_fields.push(f)
              }
            None => ()
          }
        }
        if allowed_fields.is_empty() {
          allowed_fields.push({
            name: @graphql.Name::new_unchecked("_no_fields_accessible"),
            description: None,
            info: Introspection,
            field_type: {
              base: Named(
                @graphql.TypeName(@graphql.Name::new_unchecked("String")),
              ),
              nullable: true,
            },
            default_value: None,
            deprecation_status: NotDeprecated,
          })
        }
        let arr = []
        for f in allowed_fields {
          arr.push(
            Json::object(input_value(schema, ns, f, field.selection_set)),
          )
        }
        Json::array(arr)
      }
      _ => Json::null()
    }
  })
}

///|
fn object_field(
  ns : NamespaceCtx,
  schema : Schema,
  object_field : SField,
  selection_set : NSelectionSet,
) -> Map[String, Json] raise {
  selection_set.as_object_selection_set((_t, field, field_call) => {
    match field_call.name.as_str() {
      "name" => Json::string(object_field.name.as_str())
      "description" => json_opt_string(object_field.description)
      "args" => {
        let include_deprecated = include_deprecated_arg(field_call)
        let allowed_fields : Array[SInputField] = []
        for entry in object_field.arguments.iter() {
          let (_, namespaced_field) = entry
          match ns.get(namespaced_field) {
            Some((f, _)) =>
              if !f.deprecation_status.is_deprecated() || include_deprecated {
                allowed_fields.push(f)
              }
            None => ()
          }
        }
        let arr = []
        for f in allowed_fields {
          arr.push(
            Json::object(input_value(schema, ns, f, field.selection_set)),
          )
        }
        Json::array(arr)
      }
      "type" =>
        Json::object(
          type_response(
            schema,
            ns,
            object_field.field_type,
            field.selection_set,
          ),
        )
      "isDeprecated" =>
        Json::boolean(object_field.deprecation_status.is_deprecated())
      "deprecationReason" =>
        json_opt_string(object_field.deprecation_status.reason())
      _ => Json::null()
    }
  })
}

///|
fn input_value(
  schema : Schema,
  ns : NamespaceCtx,
  input_value : SInputField,
  selection_set : NSelectionSet,
) -> Map[String, Json] raise {
  selection_set.as_object_selection_set((_t, field, field_call) => {
    match field_call.name.as_str() {
      "name" => Json::string(input_value.name.as_str())
      "description" => json_opt_string(input_value.description)
      "type" =>
        Json::object(
          type_response(schema, ns, input_value.field_type, field.selection_set),
        )
      "isDeprecated" =>
        Json::boolean(input_value.deprecation_status.is_deprecated())
      "deprecationReason" =>
        json_opt_string(input_value.deprecation_status.reason())
      _ => Json::null()
    }
  })
}

///|
fn enum_value_response(
  enum_value : SEnumValue,
  selection_set : NSelectionSet,
) -> Map[String, Json] raise {
  selection_set.as_object_selection_set((_t, _f, field_call) => {
    match field_call.name.as_str() {
      "name" => Json::string(enum_value.value.as_str())
      "description" => json_opt_string(enum_value.description)
      "isDeprecated" =>
        Json::boolean(enum_value.deprecation_status.is_deprecated())
      "deprecationReason" =>
        json_opt_string(enum_value.deprecation_status.reason())
      _ => Json::null()
    }
  })
}

///|
fn type_response(
  schema : Schema,
  ns : NamespaceCtx,
  type_ : @graphql.GType,
  selection_set : NSelectionSet,
) -> Map[String, Json] raise {
  if type_.nullable {
    base_type_response(schema, ns, type_.base, selection_set)
  } else {
    selection_set.as_object_selection_set((_t, field, field_call) => {
      match field_call.name.as_str() {
        "kind" => Json::string("NON_NULL")
        "ofType" =>
          Json::object(
            base_type_response(schema, ns, type_.base, field.selection_set),
          )
        _ => Json::null()
      }
    })
  }
}

///|
fn base_type_response(
  schema : Schema,
  ns : NamespaceCtx,
  base_type : @graphql.BaseType,
  selection_set : NSelectionSet,
) -> Map[String, Json] raise {
  match base_type {
    Named(n) => named_type_lookup_internal(schema, ns, n, selection_set)
    List(l) =>
      selection_set.as_object_selection_set((_t, field, field_call) => {
        match field_call.name.as_str() {
          "kind" => Json::string("LIST")
          "ofType" =>
            Json::object(type_response(schema, ns, l, field.selection_set))
          _ => Json::null()
        }
      })
  }
}

///|
fn collect_accessible_types(
  ns : NamespaceCtx,
  schema : Schema,
  accessible_types : Map[String, Bool],
) -> Unit {
  accessible_types[schema.query_type.as_str()] = true
  collect_accessible_types_from(ns, schema, schema.query_type, accessible_types)
  match schema.mutation_type {
    Some(mutation_type) => {
      accessible_types[mutation_type.as_str()] = true
      collect_accessible_types_from(ns, schema, mutation_type, accessible_types)
    }
    None => ()
  }
  match schema.subscription_type {
    Some(subscription_type) => {
      accessible_types[subscription_type.as_str()] = true
      collect_accessible_types_from(
        ns, schema, subscription_type, accessible_types,
      )
    }
    None => ()
  }
}

///|
fn collect_accessible_types_from(
  ns : NamespaceCtx,
  schema : Schema,
  current_type_name : @graphql.TypeName,
  accessible_types : Map[String, Bool],
) -> Unit {
  match schema.types.get(current_type_name) {
    Some(Object(object)) =>
      for entry in object.fields.iter() {
        let (_, namespaced_fields) = entry
        match ns.get(namespaced_fields) {
          Some((field, _)) => {
            for arg_entry in field.arguments.iter() {
              let (_, namespaced_input_fields) = arg_entry
              match ns.get(namespaced_input_fields) {
                Some((input_field, _)) => {
                  let input_field_type_name = underlying_type_name(
                    input_field.field_type,
                  )
                  if !accessible_types.contains(input_field_type_name.as_str()) {
                    accessible_types[input_field_type_name.as_str()] = true
                    collect_accessible_types_from(
                      ns, schema, input_field_type_name, accessible_types,
                    )
                  }
                }
                None => ()
              }
            }
            let field_type_name = underlying_type_name(field.field_type)
            if !accessible_types.contains(field_type_name.as_str()) {
              accessible_types[field_type_name.as_str()] = true
              collect_accessible_types_from(
                ns, schema, field_type_name, accessible_types,
              )
            }
          }
          None => ()
        }
      }
    Some(InputObject(input_object)) =>
      for entry in input_object.fields.iter() {
        let (_, namespaced_fields) = entry
        match ns.get(namespaced_fields) {
          Some((input_field, _)) => {
            let input_field_type_name = underlying_type_name(
              input_field.field_type,
            )
            if !accessible_types.contains(input_field_type_name.as_str()) {
              accessible_types[input_field_type_name.as_str()] = true
              collect_accessible_types_from(
                ns, schema, input_field_type_name, accessible_types,
              )
            }
          }
          None => ()
        }
      }
    _ => ()
  }
}

///|
fn is_inbuilt_type(type_info : TypeInfo) -> Bool {
  match type_info.type_name().as_str() {
    "Int" | "Float" | "Boolean" | "String" | "ID" => true
    _ => false
  }
}

///|
fn is_schema_type(type_info : TypeInfo) -> Bool {
  type_info.type_name().as_str().has_prefix("__")
}
