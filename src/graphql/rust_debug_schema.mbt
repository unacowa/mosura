// SchemaDocument の Rust {:#?} 互換プリンタ

///|
fn debug_const_argument(
  w : DebugWriter,
  indent : Int,
  a : ConstArgument,
) -> Unit {
  debug_spanning(w, indent, a, (w, i, kv) => {
    debug_key_value(w, i, kv, debug_const_value)
  })
}

///|
fn debug_const_directive(
  w : DebugWriter,
  indent : Int,
  d : ConstDirective,
) -> Unit {
  w.strukt(indent, "ConstDirective", [
    ("name", (w, i) => debug_spanning(w, i, d.name, debug_name)),
    (
      "arguments",
      (w, i) => {
        w.option(i, d.arguments, (w, i, args) => {
          debug_spanning(w, i, args, (w, i, items) => {
            w.list(i, items, debug_const_argument)
          })
        })
      },
    ),
  ])
}

///|
fn debug_const_directives(
  w : DebugWriter,
  indent : Int,
  ds : Array[Spanning[ConstDirective]],
) -> Unit {
  w.list(indent, ds, (w, i, d) => debug_spanning(w, i, d, debug_const_directive))
}

///|
fn debug_description(
  w : DebugWriter,
  indent : Int,
  d : Spanning[String]?,
) -> Unit {
  w.option(indent, d, (w, i, s) => {
    debug_spanning(w, i, s, (w, _i, str) => debug_string(w, str))
  })
}

///|
fn debug_input_value_definition(
  w : DebugWriter,
  indent : Int,
  ivd : InputValueDefinition,
) -> Unit {
  w.strukt(indent, "InputValueDefinition", [
    ("description", (w, i) => debug_description(w, i, ivd.description)),
    ("name", (w, i) => debug_spanning(w, i, ivd.name, debug_name)),
    ("ty", (w, i) => debug_spanning(w, i, ivd.ty, debug_gtype)),
    (
      "default_value",
      (w, i) => {
        w.option(i, ivd.default_value, (w, i, dv) => {
          debug_spanning(w, i, dv, debug_const_value)
        })
      },
    ),
    ("directives", (w, i) => debug_const_directives(w, i, ivd.directives)),
  ])
}

///|
fn debug_input_value_definitions(
  w : DebugWriter,
  indent : Int,
  items : Array[Spanning[InputValueDefinition]],
) -> Unit {
  w.list(indent, items, (w, i, ivd) => {
    debug_spanning(w, i, ivd, debug_input_value_definition)
  })
}

///|
fn debug_field_definition(
  w : DebugWriter,
  indent : Int,
  fd : FieldDefinition,
) -> Unit {
  w.strukt(indent, "FieldDefinition", [
    ("description", (w, i) => debug_description(w, i, fd.description)),
    ("name", (w, i) => debug_spanning(w, i, fd.name, debug_name)),
    ("arguments", (w, i) => debug_input_value_definitions(w, i, fd.arguments)),
    ("ty", (w, i) => debug_spanning(w, i, fd.ty, debug_gtype)),
    ("directives", (w, i) => debug_const_directives(w, i, fd.directives)),
  ])
}

///|
fn debug_field_definitions(
  w : DebugWriter,
  indent : Int,
  items : Array[Spanning[FieldDefinition]],
) -> Unit {
  w.list(indent, items, (w, i, fd) => {
    debug_spanning(w, i, fd, debug_field_definition)
  })
}

///|
fn debug_names(
  w : DebugWriter,
  indent : Int,
  items : Array[Spanning[Name]],
) -> Unit {
  w.list(indent, items, (w, i, n) => debug_spanning(w, i, n, debug_name))
}

///|
fn debug_type_definition(
  w : DebugWriter,
  indent : Int,
  td : TypeDefinition,
) -> Unit {
  match td {
    Scalar(d) =>
      w.tuple1(indent, "Scalar", (w, i) => {
        w.strukt(i, "ScalarTypeDefinition", [
          ("extend", (w, _i) => w.write(d.is_extension.to_string())),
          ("description", (w, i) => debug_description(w, i, d.description)),
          ("name", (w, i) => debug_spanning(w, i, d.name, debug_name)),
          ("directives", (w, i) => debug_const_directives(w, i, d.directives)),
        ])
      })
    Enum(d) =>
      w.tuple1(indent, "Enum", (w, i) => {
        w.strukt(i, "EnumTypeDefinition", [
          ("extend", (w, _i) => w.write(d.is_extension.to_string())),
          ("description", (w, i) => debug_description(w, i, d.description)),
          ("name", (w, i) => debug_spanning(w, i, d.name, debug_name)),
          ("directives", (w, i) => debug_const_directives(w, i, d.directives)),
          (
            "values",
            (w, i) => {
              w.list(i, d.values, (w, i, v) => {
                debug_spanning(w, i, v, (w, i, evd : EnumValueDefinition) => {
                  w.strukt(i, "EnumValueDefinition", [
                    (
                      "description",
                      (w, i) => debug_description(w, i, evd.description),
                    ),
                    (
                      "value",
                      (w, i) => debug_spanning(w, i, evd.value, debug_name),
                    ),
                    (
                      "directives",
                      (w, i) => debug_const_directives(w, i, evd.directives),
                    ),
                  ])
                })
              })
            },
          ),
        ])
      })
    Object(d) =>
      w.tuple1(indent, "Object", (w, i) => {
        w.strukt(i, "ObjectTypeDefinition", [
          ("extend", (w, _i) => w.write(d.is_extension.to_string())),
          ("description", (w, i) => debug_description(w, i, d.description)),
          ("name", (w, i) => debug_spanning(w, i, d.name, debug_name)),
          ("directives", (w, i) => debug_const_directives(w, i, d.directives)),
          ("implements", (w, i) => debug_names(w, i, d.implements)),
          ("fields", (w, i) => debug_field_definitions(w, i, d.fields)),
        ])
      })
    Interface(d) =>
      w.tuple1(indent, "Interface", (w, i) => {
        w.strukt(i, "InterfaceTypeDefinition", [
          ("extend", (w, _i) => w.write(d.is_extension.to_string())),
          ("description", (w, i) => debug_description(w, i, d.description)),
          ("name", (w, i) => debug_spanning(w, i, d.name, debug_name)),
          ("directives", (w, i) => debug_const_directives(w, i, d.directives)),
          ("implements", (w, i) => debug_names(w, i, d.implements)),
          ("fields", (w, i) => debug_field_definitions(w, i, d.fields)),
        ])
      })
    Union(d) =>
      w.tuple1(indent, "Union", (w, i) => {
        w.strukt(i, "UnionTypeDefinition", [
          ("extend", (w, _i) => w.write(d.is_extension.to_string())),
          ("description", (w, i) => debug_description(w, i, d.description)),
          ("name", (w, i) => debug_spanning(w, i, d.name, debug_name)),
          ("directives", (w, i) => debug_const_directives(w, i, d.directives)),
          ("members", (w, i) => debug_names(w, i, d.members)),
        ])
      })
    InputObject(d) =>
      w.tuple1(indent, "InputObject", (w, i) => {
        w.strukt(i, "InputObjectTypeDefinition", [
          ("extend", (w, _i) => w.write(d.is_extension.to_string())),
          ("description", (w, i) => debug_description(w, i, d.description)),
          ("name", (w, i) => debug_spanning(w, i, d.name, debug_name)),
          ("directives", (w, i) => debug_const_directives(w, i, d.directives)),
          ("fields", (w, i) => debug_input_value_definitions(w, i, d.fields)),
        ])
      })
  }
}

///|
fn debug_directive_location(w : DebugWriter, l : DirectiveLocation) -> Unit {
  w.write(
    match l {
      Query => "Query"
      Mutation => "Mutation"
      Subscription => "Subscription"
      Field => "Field"
      FragmentDefinition => "FragmentDefinition"
      FragmentSpread => "FragmentSpread"
      InlineFragment => "InlineFragment"
      Schema => "Schema"
      Scalar => "Scalar"
      Object => "Object"
      FieldDefinition => "FieldDefinition"
      ArgumentDefinition => "ArgumentDefinition"
      Interface => "Interface"
      Union => "Union"
      Enum => "Enum"
      EnumValue => "EnumValue"
      InputObject => "InputObject"
      InputFieldDefinition => "InputFieldDefinition"
      VariableDefinition => "VariableDefinition"
    },
  )
}

///|
fn debug_type_system_definition(
  w : DebugWriter,
  indent : Int,
  d : TypeSystemDefinition,
) -> Unit {
  match d {
    Schema(sd) =>
      w.tuple1(indent, "Schema", (w, i) => {
        w.strukt(i, "SchemaDefinition", [
          ("extend", (w, _i) => w.write(sd.is_extension.to_string())),
          ("description", (w, i) => debug_description(w, i, sd.description)),
          ("directives", (w, i) => debug_const_directives(w, i, sd.directives)),
          (
            "operation_types",
            (w, i) => {
              w.list(i, sd.operation_types, (w, i, ot) => {
                debug_spanning(w, i, ot, (
                  w,
                  i,
                  pair : (Spanning[OperationType], Spanning[Name]),
                ) => {
                  // Rust のタプル pretty Debug: `(\n    a,\n    b,\n)`
                  w.write("(\n")
                  w.pad(i + 1)
                  debug_spanning(w, i + 1, pair.0, (w, _i2, ty) => {
                    debug_operation_type(w, ty)
                  })
                  w.write(",\n")
                  w.pad(i + 1)
                  debug_spanning(w, i + 1, pair.1, debug_name)
                  w.write(",\n")
                  w.pad(i)
                  w.write(")")
                })
              })
            },
          ),
        ])
      })
    Type(td) =>
      w.tuple1(indent, "Type", (w, i) => debug_type_definition(w, i, td))
    Directive(dd) =>
      w.tuple1(indent, "Directive", (w, i) => {
        w.strukt(i, "DirectiveDefinition", [
          ("description", (w, i) => debug_description(w, i, dd.description)),
          ("name", (w, i) => debug_spanning(w, i, dd.name, debug_name)),
          (
            "arguments",
            (w, i) => debug_input_value_definitions(w, i, dd.arguments),
          ),
          (
            "locations",
            (w, i) => {
              w.list(i, dd.locations, (w, i, l) => {
                debug_spanning(w, i, l, (w, _i2, loc) => {
                  debug_directive_location(w, loc)
                })
              })
            },
          ),
        ])
      })
  }
}

///|
/// SchemaDocument を Rust の `{:#?}` と同一形式で表示する
pub fn debug_schema_document(doc : SchemaDocument) -> String {
  let w = DebugWriter::new()
  w.strukt(0, "SchemaDocument", [
    (
      "definitions",
      (w, i) => {
        w.list(i, doc.definitions, (w, i, d) => {
          debug_spanning(w, i, d, debug_type_system_definition)
        })
      },
    ),
  ])
  w.sb.to_string()
}
