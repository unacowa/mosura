// IR: 正規化済み GraphQL オペレーション → NDC QueryRequest 群
// (V3 の graphql-ir + plan に相当する Mosura 独自の接合層)

///|
pub suberror IrError {
  IrInternal(String)
  UnsupportedField(String)
} derive(Debug)

///|
pub fn IrError::display(self : IrError) -> String {
  match self {
    IrInternal(m) => "internal error: \{m}"
    UnsupportedField(f) => "unsupported field: \{f}"
  }
}

///|
/// ルートフィールドの応答形状
pub(all) enum ResponseShape {
  /// リスト (json_agg の rows をそのまま)
  ShapeList
  /// 単一オブジェクト or null (by_pk / object relationship)
  ShapeObject
}

///|
/// 実行計画上のルートフィールド
pub(all) enum RootField {
  /// DB クエリ
  RFQuery(
    alias_~ : String,
    request~ : @sqlgen.QueryRequest,
    shape~ : ResponseShape,
    selection~ : @schema.NSelectionSet
  )
  /// __typename
  RFTypename(alias_~ : String, type_name~ : String)
  /// __schema
  RFSchema(alias_~ : String, field~ : @schema.NField)
  /// __type(name:)
  RFType(alias_~ : String, field~ : @schema.NField, type_name~ : String)
}

///|
/// Mosura メタデータ → sqlgen 用 PgMetadata
/// NDC collection 名 = モデル名、カラムの NDC 名 = GraphQL フィールド名
pub fn to_pg_metadata(meta : @metadata.Metadata) -> @sqlgen.PgMetadata {
  let tables : Map[String, @sqlgen.PgTable] = Map([])
  for model_name, model in meta.models {
    let ot = meta.object_types.get(model.object_type).unwrap()
    let connector = meta.connectors.get(model.connector).unwrap()
    let columns : Map[String, @sqlgen.PgColumn] = Map([])
    for f in ot.fields {
      columns[f.name] = @sqlgen.PgColumn::{
        name: f.column,
        ty: @sqlgen.PgType::TScalar(gql_scalar_to_pg(scalar_of(f.field_type))),
      }
    }
    tables[model_name] = @sqlgen.PgTable::{
      schema_name: connector.db_schema,
      table_name: model.collection,
      columns,
    }
  }
  { tables, scalar_types: standard_scalar_types() }
}

///|
fn scalar_of(t : @graphql.GType) -> String {
  match t.base {
    Named(n) => n.as_str()
    List(inner) => scalar_of(inner)
  }
}

///|
pub fn gql_scalar_to_pg(s : String) -> String {
  match s {
    "Int" => "int4"
    "Float" => "float8"
    "Boolean" => "bool"
    "String" => "text"
    "ID" => "text"
    _ => "text"
  }
}

///|
/// 標準の比較演算子セット (int4/float8/bool/text)
pub fn standard_scalar_types() -> Map[String, @sqlgen.PgScalarType] {
  let out : Map[String, @sqlgen.PgScalarType] = Map([])
  for pg_type in ["int4", "float8", "bool", "text"] {
    let ops : Map[String, @sqlgen.PgComparisonOperator] = Map([])
    let mk = (op_name : String, kind : String) => @sqlgen.PgComparisonOperator::{
      operator_name: op_name,
      operator_kind: kind,
      argument_type: pg_type,
      is_infix: true,
    }
    ops["_eq"] = mk("=", "equal")
    ops["_neq"] = mk("<>", "custom")
    ops["_gt"] = mk(">", "custom")
    ops["_gte"] = mk(">=", "custom")
    ops["_lt"] = mk("<", "custom")
    ops["_lte"] = mk("<=", "custom")
    ops["_in"] = mk("IN", "in")
    if pg_type == "text" {
      ops["_like"] = mk("LIKE", "custom")
    }
    out[pg_type] = {
      type_name: pg_type,
      schema_name: None,
      comparison_operators: ops,
      type_representation: None,
    }
  }
  out
}

///|
/// オペレーション全体を実行計画へ
pub fn plan_operation(
  meta : @metadata.Metadata,
  op : @schema.NOperation,
) -> Array[RootField] raise {
  let out : Array[RootField] = []
  for _, field in op.selection_set.fields {
    let fc = field.field_call()
    let alias_ = field.nalias.0.as_str()
    match fc.info.generic {
      Introspection =>
        match fc.name.as_str() {
          "__typename" => out.push(RFTypename(alias_~, type_name="query_root"))
          "__schema" => out.push(RFSchema(alias_~, field~))
          "__type" => {
            let name_arg = fc.expected_argument(
              @graphql.Name::new_unchecked("name"),
            )
            let tn = name_arg.value.as_string_value()
            out.push(RFType(alias_~, field~, type_name=tn))
          }
          other => raise UnsupportedField(other)
        }
      ModelSelect(model_name) => {
        let relationships : Map[String, @sqlgen.NdcRelationship] = Map([])
        let query = build_model_query(
          meta, model_name, field, fc, relationships, false,
        )
        out.push(
          RFQuery(
            alias_~,
            request={
              collection: model_name,
              query,
              arguments: Map([]),
              collection_relationships: relationships,
              variables: None,
            },
            shape=ShapeList,
            selection=field.selection_set,
          ),
        )
      }
      ModelSelectByPk(model_name) => {
        let relationships : Map[String, @sqlgen.NdcRelationship] = Map([])
        let query = build_model_query(
          meta, model_name, field, fc, relationships, true,
        )
        out.push(
          RFQuery(
            alias_~,
            request={
              collection: model_name,
              query,
              arguments: Map([]),
              collection_relationships: relationships,
              variables: None,
            },
            shape=ShapeObject,
            selection=field.selection_set,
          ),
        )
      }
      _ => raise UnsupportedField(alias_)
    }
  }
  out
}

///|
/// モデル選択 / by_pk 共通のクエリ構築
fn build_model_query(
  meta : @metadata.Metadata,
  model_name : String,
  field : @schema.NField,
  fc : @schema.FieldCall,
  relationships : Map[String, @sqlgen.NdcRelationship],
  by_pk : Bool,
) -> @sqlgen.NdcQuery raise {
  let fields = build_selection_fields(
    meta,
    model_name,
    field.selection_set,
    relationships,
  )
  let mut predicate : @sqlgen.NdcExpression? = None
  let mut order_by : Array[@sqlgen.NdcOrderByElement]? = None
  let mut limit : Int? = None
  let mut offset : Int? = None
  if by_pk {
    let conditions : Array[@sqlgen.NdcExpression] = []
    for arg_name, arg in fc.arguments {
      conditions.push(
        @sqlgen.NdcExpression::EBinary(
          column={ name: arg_name.as_str(), path: [] },
          operator="_eq",
          value=CVScalar(arg.value.as_json()),
        ),
      )
    }
    predicate = if conditions.length() == 1 {
      Some(conditions[0])
    } else if conditions.length() > 1 {
      Some(EAnd(conditions))
    } else {
      None
    }
    limit = Some(1)
  } else {
    for arg_name, arg in fc.arguments {
      match arg_name.as_str() {
        "where" => predicate = build_bool_exp(arg.value)
        "order_by" => order_by = Some(build_order_by(arg.value))
        "limit" => limit = Some(arg.value.as_int_u32())
        "offset" => offset = Some(arg.value.as_int_u32())
        other => raise IrInternal("unknown argument: \{other}")
      }
    }
  }
  { fields: Some(fields), limit, offset, predicate, order_by }
}

///|
/// セレクションセット → NDC fields (リレーションは再帰)
fn build_selection_fields(
  meta : @metadata.Metadata,
  model_name : String,
  selection_set : @schema.NSelectionSet,
  relationships : Map[String, @sqlgen.NdcRelationship],
) -> Map[String, @sqlgen.NdcField] raise {
  let model = match meta.models.get(model_name) {
    Some(m) => m
    None => raise IrInternal("model not found: \{model_name}")
  }
  let fields : Map[String, @sqlgen.NdcField] = Map([])
  for _, f in selection_set.fields {
    let fc = f.field_call()
    let alias_ = f.nalias.0.as_str()
    match fc.info.generic {
      // __typename は SQL 側では取得しない (整形時に補う)
      Introspection => continue
      ModelField(field_name) => fields[alias_] = FColumn(column=field_name)
      RelationshipField(rel_name) => {
        let rels = match meta.relationships.get(model.object_type) {
          Some(r) => r
          None => raise IrInternal("no relationships for \{model.object_type}")
        }
        let mut found : @metadata.Relationship? = None
        for r in rels {
          if r.name == rel_name {
            found = Some(r)
          }
        }
        let rel = match found {
          Some(r) => r
          None => raise IrInternal("relationship not found: \{rel_name}")
        }
        let ndc_rel_name = "\{model.object_type}__\{rel_name}"
        relationships[ndc_rel_name] = @sqlgen.NdcRelationship::{
          column_mapping: rel.mapping,
          relationship_type: match rel.kind {
            RelObject => "object"
            RelArray => "array"
          },
          target_collection: rel.target_model,
          arguments: Map([]),
        }
        let sub_fields = build_selection_fields(
          meta,
          rel.target_model,
          f.selection_set,
          relationships,
        )
        let mut predicate : @sqlgen.NdcExpression? = None
        let mut order_by : Array[@sqlgen.NdcOrderByElement]? = None
        let mut limit : Int? = None
        let mut offset : Int? = None
        for arg_name, arg in fc.arguments {
          match arg_name.as_str() {
            "where" => predicate = build_bool_exp(arg.value)
            "order_by" => order_by = Some(build_order_by(arg.value))
            "limit" => limit = Some(arg.value.as_int_u32())
            "offset" => offset = Some(arg.value.as_int_u32())
            other => raise IrInternal("unknown argument: \{other}")
          }
        }
        match rel.kind {
          RelObject => limit = Some(1)
          RelArray => ()
        }
        fields[alias_] = FRelationship(
          query={ fields: Some(sub_fields), limit, offset, predicate, order_by },
          relationship=ndc_rel_name,
          arguments=Map([]),
        )
      }
      _ => raise UnsupportedField(alias_)
    }
  }
  fields
}

///|
/// bool_exp の正規化済み値 → NdcExpression
pub fn build_bool_exp(value : @schema.NValue) -> @sqlgen.NdcExpression? raise {
  match value {
    SimpleValue(NNull) => None
    Object(fields) => {
      let conditions : Array[@sqlgen.NdcExpression] = []
      for _, f in fields {
        match f.info.generic {
          InputArg(BoolExpLogical(op)) =>
            match op {
              "_and" | "_or" => {
                if f.value.is_null() {
                  continue
                }
                let items : Array[@sqlgen.NdcExpression] = []
                for item in f.value.as_list() {
                  match build_bool_exp(item) {
                    Some(e) => items.push(e)
                    None => ()
                  }
                }
                if op == "_and" {
                  conditions.push(EAnd(items))
                } else {
                  conditions.push(EOr(items))
                }
              }
              "_not" =>
                match build_bool_exp(f.value) {
                  Some(e) => conditions.push(ENot(e))
                  None => ()
                }
              other => raise IrInternal("unknown logical op: \{other}")
            }
          InputArg(BoolExpField(field_name)) => {
            if f.value.is_null() {
              continue
            }
            for _, op_field in f.value.as_object_value() {
              match op_field.info.generic {
                InputArg(BoolExpOperator(op)) =>
                  if op == "_is_null" {
                    let is_null = op_field.value.as_boolean()
                    let base = @sqlgen.NdcExpression::EUnaryIsNull(column={
                      name: field_name,
                      path: [],
                    })
                    conditions.push(if is_null { base } else { ENot(base) })
                  } else {
                    conditions.push(
                      EBinary(
                        column={ name: field_name, path: [] },
                        operator=op,
                        value=CVScalar(op_field.value.as_json()),
                      ),
                    )
                  }
                _ => raise IrInternal("unexpected bool_exp operator field")
              }
            }
          }
          _ => raise IrInternal("unexpected bool_exp field")
        }
      }
      if conditions.is_empty() {
        None
      } else if conditions.length() == 1 {
        Some(conditions[0])
      } else {
        Some(EAnd(conditions))
      }
    }
    _ => None
  }
}

///|
/// order_by の正規化済み値 → NDC order by
fn build_order_by(
  value : @schema.NValue,
) -> Array[@sqlgen.NdcOrderByElement] raise {
  let out : Array[@sqlgen.NdcOrderByElement] = []
  match value {
    List(items) =>
      for item in items {
        for _, f in item.as_object_value() {
          match f.info.generic {
            InputArg(OrderByField(field_name)) => {
              let dir = match f.value {
                SimpleValue(NEnum(name~, ..)) => name.as_str()
                _ => raise IrInternal("order_by value must be enum")
              }
              let direction = if dir.has_prefix("asc") { "asc" } else { "desc" }
              out.push({
                order_direction: direction,
                target_name: field_name,
                target_path: [],
              })
            }
            _ => raise IrInternal("unexpected order_by field")
          }
        }
      }
    SimpleValue(NNull) => ()
    _ => raise IrInternal("order_by must be a list")
  }
  out
}
