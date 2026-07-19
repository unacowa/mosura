// ndc-postgres の configuration metadata サブセット (tables + scalar types)

///|
pub(all) enum PgType {
  TScalar(String)
  TArray(PgType)
  TComposite(String)
}

///|
pub(all) struct PgColumn {
  name : String
  ty : PgType
}

///|
pub(all) struct PgTable {
  schema_name : String
  table_name : String
  /// NDC 名 → カラム情報
  columns : Map[String, PgColumn]
}

///|
pub(all) struct PgComparisonOperator {
  operator_name : String
  operator_kind : String
  argument_type : String
  is_infix : Bool
}

///|
pub(all) struct PgScalarType {
  type_name : String
  schema_name : String?
  comparison_operators : Map[String, PgComparisonOperator]
  type_representation : String?
}

///|
pub(all) struct PgMetadata {
  tables : Map[String, PgTable]
  scalar_types : Map[String, PgScalarType]
}

///|
/// configuration.json (の metadata 部) をデコード
pub fn decode_pg_metadata(config : Json) -> PgMetadata raise NdcDecodeError {
  let m = match jget(config, "metadata") {
    Some(x) => x
    None => config
  }
  let tables : Map[String, PgTable] = Map([])
  match jget(m, "tables") {
    Some(Json::Object(ts)) =>
      for name, t in ts {
        let columns : Map[String, PgColumn] = Map([])
        match jget(t, "columns") {
          Some(Json::Object(cs)) =>
            for cname, c in cs {
              columns[cname] = {
                name: jstr(c, "name"),
                ty: match jget(c, "type") {
                  Some(ty) => decode_pg_type(ty)
                  None => raise NdcDecode("missing column type")
                },
              }
            }
          _ => ()
        }
        tables[name] = {
          schema_name: jstr(t, "schemaName"),
          table_name: jstr(t, "tableName"),
          columns,
        }
      }
    _ => ()
  }
  let scalar_types : Map[String, PgScalarType] = Map([])
  match jget(m, "types") {
    Some(types) =>
      match jget(types, "scalar") {
        Some(Json::Object(sts)) =>
          for name, st in sts {
            let comparison_operators : Map[String, PgComparisonOperator] = Map([])
            match jget(st, "comparisonOperators") {
              Some(Json::Object(ops)) =>
                for opname, op in ops {
                  comparison_operators[opname] = {
                    operator_name: jstr(op, "operatorName"),
                    operator_kind: jstr(op, "operatorKind"),
                    argument_type: jstr(op, "argumentType"),
                    is_infix: match jget(op, "isInfix") {
                      Some(Json::False) => false
                      _ => true
                    },
                  }
                }
              _ => ()
            }
            scalar_types[name] = {
              type_name: jstr(st, "typeName"),
              schema_name: match jget(st, "schemaName") {
                Some(Json::String(s)) => Some(s)
                _ => None
              },
              comparison_operators,
              type_representation: match jget(st, "typeRepresentation") {
                Some(Json::String(s)) => Some(s)
                _ => None
              },
            }
          }
        _ => ()
      }
    None => ()
  }
  { tables, scalar_types }
}

///|
fn decode_pg_type(j : Json) -> PgType raise NdcDecodeError {
  match jget(j, "scalarType") {
    Some(Json::String(s)) => return TScalar(s)
    _ => ()
  }
  match jget(j, "arrayType") {
    Some(inner) => return TArray(decode_pg_type(inner))
    None => ()
  }
  match jget(j, "compositeType") {
    Some(Json::String(s)) => return TComposite(s)
    _ => ()
  }
  raise NdcDecode("unknown pg type")
}
