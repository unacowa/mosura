// NDC (ndc-models) リクエスト型のサブセットと JSON デコード。
// ndc-postgres translation ゴールデンの request.json 形式 (query のみ、aggregates/nested fields は対象外)

///|
pub suberror NdcDecodeError {
  NdcDecode(String)
} derive(Debug)

///|
pub(all) struct QueryRequest {
  collection : String
  query : NdcQuery
  arguments : Map[String, NdcArgument]
  collection_relationships : Map[String, NdcRelationship]
  variables : Array[Map[String, Json]]?
}

///|
pub(all) struct NdcQuery {
  fields : Map[String, NdcField]?
  limit : Int?
  offset : Int?
  predicate : NdcExpression?
  order_by : Array[NdcOrderByElement]?
}

///|
pub(all) enum NdcField {
  FColumn(column~ : String)
  FRelationship(
    query~ : NdcQuery,
    relationship~ : String,
    arguments~ : Map[String, NdcArgument]
  )
}

///|
pub(all) enum NdcArgument {
  ALiteral(Json)
  AVariable(String)
}

///|
pub(all) struct NdcRelationship {
  column_mapping : Array[(String, String)]
  relationship_type : String
  target_collection : String
  arguments : Map[String, NdcArgument]
}

///|
pub(all) enum NdcExpression {
  EAnd(Array[NdcExpression])
  EOr(Array[NdcExpression])
  ENot(NdcExpression)
  EBinary(
    column~ : NdcComparisonTarget,
    operator~ : String,
    value~ : NdcComparisonValue
  )
  EUnaryIsNull(column~ : NdcComparisonTarget)
  EExistsRelated(
    relationship~ : String,
    arguments~ : Map[String, NdcArgument],
    predicate~ : NdcExpression?
  )
  EExistsUnrelated(
    collection~ : String,
    arguments~ : Map[String, NdcArgument],
    predicate~ : NdcExpression?
  )
}

///|
pub(all) struct NdcComparisonTarget {
  name : String
  path : Array[NdcPathElement]
}

///|
pub(all) enum NdcComparisonValue {
  CVColumn(name~ : String, path~ : Array[NdcPathElement], scope~ : Int?)
  CVScalar(Json)
  CVVariable(String)
}

///|
pub(all) struct NdcPathElement {
  relationship : String
  arguments : Map[String, NdcArgument]
  predicate : NdcExpression?
}

///|
pub(all) struct NdcOrderByElement {
  order_direction : String
  target_name : String
  target_path : Array[NdcPathElement]
}

// --- JSON デコード ---

///|
fn jget(j : Json, key : String) -> Json? {
  match j {
    Json::Object(m) => m.get(key)
    _ => None
  }
}

///|
fn jstr(j : Json, key : String) -> String raise NdcDecodeError {
  match jget(j, key) {
    Some(Json::String(s)) => s
    _ => raise NdcDecode("expected string at '\{key}'")
  }
}

///|
fn jint(j : Json, key : String) -> Int? {
  match jget(j, key) {
    Some(Json::Number(d, ..)) => Some(d.to_int())
    _ => None
  }
}

///|
pub fn decode_query_request(j : Json) -> QueryRequest raise NdcDecodeError {
  let collection = jstr(j, "collection")
  let query = match jget(j, "query") {
    Some(q) => decode_query(q)
    None => raise NdcDecode("missing query")
  }
  let arguments = decode_arguments(jget(j, "arguments"))
  let collection_relationships : Map[String, NdcRelationship] = Map([])
  match jget(j, "collection_relationships") {
    Some(Json::Object(m)) =>
      for name, rel in m {
        collection_relationships[name] = decode_relationship(rel)
      }
    _ => ()
  }
  let variables : Array[Map[String, Json]]? = match jget(j, "variables") {
    Some(Json::Array(items)) => {
      let out : Array[Map[String, Json]] = []
      for item in items {
        match item {
          Json::Object(m) => {
            let vm : Map[String, Json] = Map([])
            for k, v in m {
              vm[k] = v
            }
            out.push(vm)
          }
          _ => raise NdcDecode("variables item must be object")
        }
      }
      Some(out)
    }
    _ => None
  }
  { collection, query, arguments, collection_relationships, variables }
}

///|
fn decode_query(j : Json) -> NdcQuery raise NdcDecodeError {
  match jget(j, "aggregates") {
    Some(Json::Null) | None => ()
    Some(_) => raise NdcDecode("aggregates not supported")
  }
  let fields : Map[String, NdcField]? = match jget(j, "fields") {
    Some(Json::Object(m)) => {
      let out : Map[String, NdcField] = Map([])
      for name, f in m {
        out[name] = decode_field(f)
      }
      Some(out)
    }
    _ => None
  }
  let predicate = match jget(j, "predicate") {
    Some(Json::Null) | None => None
    Some(p) => Some(decode_expression(p))
  }
  let order_by : Array[NdcOrderByElement]? = match jget(j, "order_by") {
    Some(ob) =>
      match jget(ob, "elements") {
        Some(Json::Array(items)) => {
          let out = []
          for item in items {
            let direction = jstr(item, "order_direction")
            let target = match jget(item, "target") {
              Some(t) => t
              None => raise NdcDecode("missing order_by target")
            }
            match jget(target, "type") {
              Some(Json::String("column")) => ()
              _ => raise NdcDecode("unsupported order_by target type")
            }
            // field_path (ネスト/JSON フィールドのソート) は未対応。
            // 黙って落とすと最上位カラムでソートされてしまうため明示的に拒否する
            match jget(target, "field_path") {
              Some(Json::Null) | None => ()
              Some(Json::Array(fp)) =>
                if !fp.is_empty() {
                  raise NdcDecode(
                    "order_by target field_path (nested field ordering) not supported",
                  )
                }
              Some(_) =>
                raise NdcDecode(
                  "order_by target field_path (nested field ordering) not supported",
                )
            }
            out.push(NdcOrderByElement::{
              order_direction: direction,
              target_name: jstr(target, "name"),
              target_path: decode_path(jget(target, "path")),
            })
          }
          Some(out)
        }
        _ => None
      }
    None => None
  }
  {
    fields,
    limit: jint(j, "limit"),
    offset: jint(j, "offset"),
    predicate,
    order_by,
  }
}

///|
fn decode_field(j : Json) -> NdcField raise NdcDecodeError {
  match jget(j, "type") {
    Some(Json::String("column")) =>
      // ネストフィールド (fields) は対象外
      match jget(j, "fields") {
        Some(Json::Null) | None => FColumn(column=jstr(j, "column"))
        Some(_) => raise NdcDecode("nested fields not supported")
      }
    Some(Json::String("relationship")) =>
      FRelationship(
        query=match jget(j, "query") {
          Some(q) => decode_query(q)
          None => raise NdcDecode("missing relationship query")
        },
        relationship=jstr(j, "relationship"),
        arguments=decode_arguments(jget(j, "arguments")),
      )
    _ => raise NdcDecode("unknown field type")
  }
}

///|
fn decode_arguments(j : Json?) -> Map[String, NdcArgument] raise NdcDecodeError {
  let out : Map[String, NdcArgument] = Map([])
  match j {
    Some(Json::Object(m)) =>
      for name, a in m {
        out[name] = match jget(a, "type") {
          Some(Json::String("literal")) =>
            ALiteral(
              match jget(a, "value") {
                Some(v) => v
                None => Json::null()
              },
            )
          Some(Json::String("variable")) => AVariable(jstr(a, "name"))
          _ => raise NdcDecode("unknown argument type")
        }
      }
    _ => ()
  }
  out
}

///|
fn decode_relationship(j : Json) -> NdcRelationship raise NdcDecodeError {
  let column_mapping : Array[(String, String)] = []
  match jget(j, "column_mapping") {
    Some(Json::Object(m)) =>
      for source, target in m {
        match target {
          Json::String(t) => column_mapping.push((source, t))
          Json::Array([Json::String(t)]) => column_mapping.push((source, t))
          _ => raise NdcDecode("unsupported column_mapping target")
        }
      }
    _ => ()
  }
  {
    column_mapping,
    relationship_type: jstr(j, "relationship_type"),
    target_collection: jstr(j, "target_collection"),
    arguments: decode_arguments(jget(j, "arguments")),
  }
}

///|
fn decode_path(j : Json?) -> Array[NdcPathElement] raise NdcDecodeError {
  let out : Array[NdcPathElement] = []
  match j {
    Some(Json::Array(items)) =>
      for item in items {
        out.push({
          relationship: jstr(item, "relationship"),
          arguments: decode_arguments(jget(item, "arguments")),
          predicate: match jget(item, "predicate") {
            Some(Json::Null) | None => None
            Some(p) => Some(decode_expression(p))
          },
        })
      }
    _ => ()
  }
  out
}

///|
fn decode_comparison_target(
  j : Json,
) -> NdcComparisonTarget raise NdcDecodeError {
  match jget(j, "type") {
    Some(Json::String("column")) => ()
    _ => raise NdcDecode("unsupported comparison target")
  }
  { name: jstr(j, "name"), path: decode_path(jget(j, "path")) }
}

///|
fn decode_expression(j : Json) -> NdcExpression raise NdcDecodeError {
  match jget(j, "type") {
    Some(Json::String("and")) => {
      let exprs = []
      match jget(j, "expressions") {
        Some(Json::Array(items)) =>
          for item in items {
            exprs.push(decode_expression(item))
          }
        _ => ()
      }
      EAnd(exprs)
    }
    Some(Json::String("or")) => {
      let exprs = []
      match jget(j, "expressions") {
        Some(Json::Array(items)) =>
          for item in items {
            exprs.push(decode_expression(item))
          }
        _ => ()
      }
      EOr(exprs)
    }
    Some(Json::String("not")) =>
      ENot(
        match jget(j, "expression") {
          Some(e) => decode_expression(e)
          None => raise NdcDecode("missing not expression")
        },
      )
    Some(Json::String("binary_comparison_operator")) => {
      let column = match jget(j, "column") {
        Some(c) => decode_comparison_target(c)
        None => raise NdcDecode("missing column")
      }
      let operator = jstr(j, "operator")
      let value = match jget(j, "value") {
        Some(v) =>
          match jget(v, "type") {
            Some(Json::String("scalar")) =>
              CVScalar(
                match jget(v, "value") {
                  Some(sv) => sv
                  None => Json::null()
                },
              )
            Some(Json::String("variable")) => CVVariable(jstr(v, "name"))
            Some(Json::String("column")) => {
              // v0.2 では column オブジェクトの中に name/path/scope
              let scope = jint(v, "scope")
              match jget(v, "column") {
                Some(c) =>
                  CVColumn(
                    name=jstr(c, "name"),
                    path=decode_path(jget(c, "path")),
                    scope~,
                  )
                None =>
                  CVColumn(
                    name=jstr(v, "name"),
                    path=decode_path(jget(v, "path")),
                    scope~,
                  )
              }
            }
            _ => raise NdcDecode("unknown comparison value type")
          }
        None => raise NdcDecode("missing value")
      }
      EBinary(column~, operator~, value~)
    }
    Some(Json::String("unary_comparison_operator")) => {
      match jget(j, "operator") {
        Some(Json::String("is_null")) => ()
        _ => raise NdcDecode("unknown unary operator")
      }
      EUnaryIsNull(
        column=match jget(j, "column") {
          Some(c) => decode_comparison_target(c)
          None => raise NdcDecode("missing column")
        },
      )
    }
    Some(Json::String("exists")) => {
      let predicate = match jget(j, "predicate") {
        Some(Json::Null) | None => None
        Some(p) => Some(decode_expression(p))
      }
      match jget(j, "in_collection") {
        Some(ic) =>
          match jget(ic, "type") {
            Some(Json::String("related")) =>
              EExistsRelated(
                relationship=jstr(ic, "relationship"),
                arguments=decode_arguments(jget(ic, "arguments")),
                predicate~,
              )
            Some(Json::String("unrelated")) =>
              EExistsUnrelated(
                collection=jstr(ic, "collection"),
                arguments=decode_arguments(jget(ic, "arguments")),
                predicate~,
              )
            _ => raise NdcDecode("unsupported in_collection type")
          }
        None => raise NdcDecode("missing in_collection")
      }
    }
    _ => raise NdcDecode("unknown expression type")
  }
}
