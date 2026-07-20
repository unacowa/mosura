// IR: 正規化済み GraphQL オペレーション → NDC QueryRequest 群
// (V3 の graphql-ir + plan に相当する Mosura 独自の接合層)

///|
pub suberror IrError {
  /// エンジン側の不整合 (ユーザには "internal error" として返す)
  IrInternal(String)
  /// ロール権限による拒否 (スキーマ可視性で弾かれるはずの防御的検査)
  IrPermissionDenied(String)
  /// リクエスト起因のエラー (不正な入力・セッション変数不足など)
  IrBadRequest(String)
  UnsupportedField(String)
} derive(Debug)

///|
pub fn IrError::display(self : IrError) -> String {
  match self {
    IrInternal(m) => "internal error: \{m}"
    IrPermissionDenied(m) => m
    IrBadRequest(m) => m
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
  /// ミューテーション (SQL 構築済み)
  RFMutation(
    alias_~ : String,
    sql~ : @sqlgen.SQL,
    model~ : String,
    kind~ : MutationKind,
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
pub(all) enum MutationKind {
  MInsert
  MUpdateByPk
  MDeleteByPk
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
      // テキスト検索演算子 (すべて infix。PG のキーワード/演算子へマップ)
      ops["_like"] = mk("LIKE", "custom")
      ops["_nlike"] = mk("NOT LIKE", "custom")
      ops["_ilike"] = mk("ILIKE", "custom")
      ops["_nilike"] = mk("NOT ILIKE", "custom")
      ops["_similar"] = mk("SIMILAR TO", "custom")
      ops["_nsimilar"] = mk("NOT SIMILAR TO", "custom")
      ops["_regex"] = mk("~", "custom")
      ops["_iregex"] = mk("~*", "custom")
      ops["_nregex"] = mk("!~", "custom")
      ops["_niregex"] = mk("!~*", "custom")
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
  pg_meta : @sqlgen.PgMetadata,
  session : @session.Session,
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
          meta, session, model_name, field, fc, relationships, false,
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
          meta, session, model_name, field, fc, relationships, true,
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
      ModelInsert(model_name) => {
        let perm = mutation_permission(meta, session, model_name)
        let insert_perm = match perm {
          Some(p) =>
            match p.insert {
              Some(ins) => Some(ins)
              None =>
                raise IrPermissionDenied(
                  "insert into \{model_name} is not allowed for this role",
                )
            }
          None => None
        }
        let objects_arg = fc.expected_argument(
          @graphql.Name::new_unchecked("objects"),
        )
        let rows : Array[Array[(String, Json)]] = []
        for item in objects_arg.value.as_list() {
          let row : Array[(String, Json)] = []
          for fname, fvalue in item.as_object_value() {
            row.push((fname.as_str(), fvalue.value.as_json()))
          }
          rows.push(row)
        }
        if rows.is_empty() {
          raise IrBadRequest("insert requires at least one object")
        }
        // ロールの許可カラム検査 + プリセット適用 + post-write CHECK
        let check = match insert_perm {
          Some(ins) => {
            for row in rows {
              check_allowed_columns(
                col => ins.allows_column(col),
                row,
                model_name,
              )
            }
            apply_presets(rows, ins.presets, session)
            match ins.check {
              Some(check_json) => permission_filter_to_ndc(check_json, session)
              None => None
            }
          }
          None => None
        }
        let returning = returning_from_mutation_response(field.selection_set)
        let sql = @sqlgen.build_insert_sql(
          pg_meta,
          model_name,
          rows,
          returning,
          check~,
        )
        out.push(
          RFMutation(
            alias_~,
            sql~,
            model=model_name,
            kind=MInsert,
            selection=field.selection_set,
          ),
        )
      }
      ModelUpdateByPk(model_name) => {
        let perm = mutation_permission(meta, session, model_name)
        let update_perm = match perm {
          Some(p) =>
            match p.update {
              Some(upd) => Some(upd)
              None =>
                raise IrPermissionDenied(
                  "update on \{model_name} is not allowed for this role",
                )
            }
          None => None
        }
        let pk : Array[(String, Json)] = []
        let set_ : Array[(String, Json)] = []
        for arg_name, arg in fc.arguments {
          if arg_name.as_str() == "_set" {
            for fname, fvalue in arg.value.as_object_value() {
              set_.push((fname.as_str(), fvalue.value.as_json()))
            }
          } else {
            pk.push((arg_name.as_str(), arg.value.as_json()))
          }
        }
        if set_.is_empty() {
          raise IrBadRequest("_set must not be empty")
        }
        // ロールの許可カラム検査 + プリセット適用 + 行フィルタ + post-write CHECK
        let (filter, check) = match update_perm {
          Some(upd) => {
            check_allowed_columns(
              col => upd.allows_column(col),
              set_,
              model_name,
            )
            apply_presets([set_], upd.presets, session)
            let filter = match upd.filter {
              Some(filter_json) =>
                permission_filter_to_ndc(filter_json, session)
              None => None
            }
            let check = match upd.check {
              Some(check_json) => permission_filter_to_ndc(check_json, session)
              None => None
            }
            (filter, check)
          }
          None => (None, None)
        }
        let returning = returning_from_selection(field.selection_set)
        let sql = @sqlgen.build_update_by_pk_sql(
          pg_meta,
          model_name,
          pk,
          set_,
          returning,
          filter~,
          check~,
        )
        out.push(
          RFMutation(
            alias_~,
            sql~,
            model=model_name,
            kind=MUpdateByPk,
            selection=field.selection_set,
          ),
        )
      }
      ModelDeleteByPk(model_name) => {
        let perm = mutation_permission(meta, session, model_name)
        let filter = match perm {
          Some(p) =>
            match p.delete {
              Some(del) =>
                match del.filter {
                  Some(filter_json) =>
                    permission_filter_to_ndc(filter_json, session)
                  None => None
                }
              None =>
                raise IrPermissionDenied(
                  "delete on \{model_name} is not allowed for this role",
                )
            }
          None => None
        }
        let pk : Array[(String, Json)] = []
        for arg_name, arg in fc.arguments {
          pk.push((arg_name.as_str(), arg.value.as_json()))
        }
        let returning = returning_from_selection(field.selection_set)
        let sql = @sqlgen.build_delete_by_pk_sql(
          pg_meta,
          model_name,
          pk,
          returning,
          filter~,
        )
        out.push(
          RFMutation(
            alias_~,
            sql~,
            model=model_name,
            kind=MDeleteByPk,
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
/// mutation_response の returning セレクションから RETURNING 句を作る
/// (alias, NDC カラム名) の配列
fn returning_from_mutation_response(
  selection : @schema.NSelectionSet,
) -> Array[(String, String)] raise {
  for _, f in selection.fields {
    let fc = f.field_call()
    match fc.info.generic {
      ReturningRows(_) => return returning_from_selection(f.selection_set)
      _ => ()
    }
  }
  // returning が選択されていなくても RETURNING は必要 (affected_rows 計上のため)
  []
}

///|
/// オブジェクトのセレクション (ModelField のみ) を RETURNING 対応に変換
fn returning_from_selection(
  selection : @schema.NSelectionSet,
) -> Array[(String, String)] raise {
  let out : Array[(String, String)] = []
  for _, f in selection.fields {
    let fc = f.field_call()
    match fc.info.generic {
      ModelField(field_name) => out.push((f.nalias.0.as_str(), field_name))
      Introspection => ()
      _ => raise UnsupportedField("relationships in mutation returning")
    }
  }
  out
}

///|
/// モデル選択 / by_pk 共通のクエリ構築
fn build_model_query(
  meta : @metadata.Metadata,
  session : @session.Session,
  model_name : String,
  field : @schema.NField,
  fc : @schema.FieldCall,
  relationships : Map[String, @sqlgen.NdcRelationship],
  by_pk : Bool,
) -> @sqlgen.NdcQuery raise {
  let fields = build_selection_fields(
    meta,
    session,
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
        "where" =>
          predicate = build_bool_exp(
            meta,
            session,
            model_name,
            relationships,
            arg.value,
          )
        "order_by" =>
          order_by = Some(
            build_order_by(meta, session, model_name, relationships, arg.value),
          )
        "limit" => limit = Some(arg.value.as_int_u32())
        "offset" => offset = Some(arg.value.as_int_u32())
        other => raise IrInternal("unknown argument: \{other}")
      }
    }
  }
  let predicate = apply_permission_filter(meta, session, model_name, predicate)
  { fields: Some(fields), aggregates: None, limit, offset, predicate, order_by }
}

///|
/// ロールの行フィルタを predicate に AND する
fn apply_permission_filter(
  meta : @metadata.Metadata,
  session : @session.Session,
  model_name : String,
  predicate : @sqlgen.NdcExpression?,
) -> @sqlgen.NdcExpression? raise {
  if session.is_admin() {
    return predicate
  }
  let mp = match meta.model_permissions.get(model_name) {
    Some(mp) => mp
    // スキーマ可視性で弾かれているはずだが防御的にエラー
    None => raise IrInternal("no permissions for model \{model_name}")
  }
  let mut permission : @metadata.ModelPermission? = None
  for p in mp.permissions {
    if p.role == session.role {
      permission = Some(p)
    }
  }
  let permission = match permission {
    Some(p) => p
    None =>
      raise IrPermissionDenied(
        "model \{model_name} is not accessible for this role",
      )
  }
  let filter_expr = match permission.filter {
    None => None
    Some(filter_json) => permission_filter_to_ndc(filter_json, session)
  }
  match (predicate, filter_expr) {
    (None, None) => None
    (Some(p), None) => Some(p)
    (None, Some(f)) => Some(f)
    (Some(p), Some(f)) => Some(EAnd([f, p]))
  }
}

///|
/// ミューテーション用のロール権限を引く (admin は無制限なので None)
fn mutation_permission(
  meta : @metadata.Metadata,
  session : @session.Session,
  model_name : String,
) -> @metadata.ModelPermission? raise {
  if session.is_admin() {
    return None
  }
  let mp = match meta.model_permissions.get(model_name) {
    Some(mp) => mp
    None => raise IrInternal("no permissions for model \{model_name}")
  }
  for p in mp.permissions {
    if p.role == session.role {
      return Some(p)
    }
  }
  raise IrPermissionDenied(
    "model \{model_name} is not accessible for this role",
  )
}

///|
/// 入力カラムが許可判定 (allows_column) を通るか検査する (スキーマ可視性で
/// 弾かれているはずだが防御的に再検査する)。判定ルールの実体は
/// @metadata.InsertPermission::allows_column / UpdatePermission::allows_column
fn check_allowed_columns(
  allows : (String) -> Bool,
  row : Array[(String, Json)],
  model_name : String,
) -> Unit raise {
  for pair in row {
    let (field_name, _) = pair
    if !allows(field_name) {
      raise IrPermissionDenied(
        "column \{field_name} of \{model_name} is not allowed for this role",
      )
    }
  }
}

///|
/// {sessionVariable: "..."} / {literal: ...} 形式の権限値をセッションで解決する。
/// どちらのキーも無いオブジェクトはメタデータ不備 (internal)、
/// セッション変数の欠如はリクエスト起因 (bad request)。
/// オブジェクト以外の JSON はリテラルとしてそのまま返す
fn resolve_permission_value(
  value : Json,
  session : @session.Session,
  context : String,
) -> Json raise {
  match value {
    Json::Object(v) =>
      match v.get("sessionVariable") {
        Some(Json::String(var_name)) =>
          match session.variables.get(var_name.to_lower()) {
            Some(s) => Json::string(s)
            None =>
              raise IrBadRequest("session variable not provided: \{var_name}")
          }
        _ =>
          match v.get("literal") {
            Some(lit) => lit
            None =>
              raise IrInternal(
                "\{context} must have sessionVariable or literal",
              )
          }
      }
    other => other
  }
}

///|
/// カラムプリセットを各行に適用する。
/// value は {sessionVariable: "..."} または {literal: ...}
fn apply_presets(
  rows : Array[Array[(String, Json)]],
  presets : Array[@metadata.FieldPreset],
  session : @session.Session,
) -> Unit raise {
  for preset in presets {
    let value = resolve_permission_value(preset.value, session, "preset value")
    for row in rows {
      row.push((preset.field, value))
    }
  }
}

///|
/// ModelPermissions の filter JSON → NdcExpression
/// 形式: {fieldComparison: {field, operator, value: {sessionVariable|literal}}}
///       {and: [...]}, {or: [...]}, {not: {...}}
pub fn permission_filter_to_ndc(
  filter : Json,
  session : @session.Session,
) -> @sqlgen.NdcExpression? raise {
  match filter {
    Json::Object(m) => {
      match m.get("fieldComparison") {
        Some(fc) => {
          let field = match fc {
            Json::Object(f) =>
              match f.get("field") {
                Some(Json::String(s)) => s
                _ => raise IrInternal("fieldComparison.field must be a string")
              }
            _ => raise IrInternal("fieldComparison must be an object")
          }
          let operator = match fc {
            Json::Object(f) =>
              match f.get("operator") {
                Some(Json::String(s)) => s
                _ => "_eq"
              }
            _ => "_eq"
          }
          let value_json : Json = match fc {
            Json::Object(f) =>
              match f.get("value") {
                Some(v) =>
                  resolve_permission_value(v, session, "fieldComparison.value")
                None => raise IrInternal("fieldComparison.value is required")
              }
            _ => Json::null()
          }
          return Some(
            EBinary(
              column={ name: field, path: [] },
              operator~,
              value=CVScalar(value_json),
            ),
          )
        }
        None => ()
      }
      match m.get("and") {
        Some(Json::Array(items)) => {
          let exprs : Array[@sqlgen.NdcExpression] = []
          for item in items {
            match permission_filter_to_ndc(item, session) {
              Some(e) => exprs.push(e)
              None => ()
            }
          }
          return Some(EAnd(exprs))
        }
        _ => ()
      }
      match m.get("or") {
        Some(Json::Array(items)) => {
          let exprs : Array[@sqlgen.NdcExpression] = []
          for item in items {
            match permission_filter_to_ndc(item, session) {
              Some(e) => exprs.push(e)
              None => ()
            }
          }
          return Some(EOr(exprs))
        }
        _ => ()
      }
      match m.get("not") {
        Some(inner) =>
          return match permission_filter_to_ndc(inner, session) {
            Some(e) => Some(ENot(e))
            None => None
          }
        None => ()
      }
      None
    }
    Json::Null => None
    _ => raise IrInternal("invalid permission filter")
  }
}

///|
/// モデルの object type 上のリレーション定義を引く
fn lookup_relationship_def(
  meta : @metadata.Metadata,
  model_name : String,
  rel_name : String,
) -> @metadata.Relationship raise {
  let model = match meta.models.get(model_name) {
    Some(m) => m
    None => raise IrInternal("model not found: \{model_name}")
  }
  let rels = match meta.relationships.get(model.object_type) {
    Some(r) => r
    None => raise IrInternal("no relationships for \{model.object_type}")
  }
  for r in rels {
    if r.name == rel_name {
      return r
    }
  }
  raise IrInternal("relationship not found: \{rel_name}")
}

///|
/// NDC リクエストの collection_relationships にリレーションを登録し、
/// その NDC 名 ("<object_type>__<rel名>") を返す
fn register_ndc_relationship(
  meta : @metadata.Metadata,
  model_name : String,
  rel_name : String,
  rel : @metadata.Relationship,
  relationships : Map[String, @sqlgen.NdcRelationship],
) -> String raise {
  let model = match meta.models.get(model_name) {
    Some(m) => m
    None => raise IrInternal("model not found: \{model_name}")
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
  ndc_rel_name
}

///|
/// セレクションセット → NDC fields (リレーションは再帰)
fn build_selection_fields(
  meta : @metadata.Metadata,
  session : @session.Session,
  model_name : String,
  selection_set : @schema.NSelectionSet,
  relationships : Map[String, @sqlgen.NdcRelationship],
) -> Map[String, @sqlgen.NdcField] raise {
  // リレーション定義は lookup_relationship_def が model_name から解決する
  let fields : Map[String, @sqlgen.NdcField] = Map([])
  for _, f in selection_set.fields {
    let fc = f.field_call()
    let alias_ = f.nalias.0.as_str()
    match fc.info.generic {
      // __typename は SQL 側では取得しない (整形時に補う)
      Introspection => continue
      ModelField(field_name) => fields[alias_] = FColumn(column=field_name)
      RelationshipField(rel_name) => {
        let rel = lookup_relationship_def(meta, model_name, rel_name)
        let ndc_rel_name = register_ndc_relationship(
          meta, model_name, rel_name, rel, relationships,
        )
        let sub_fields = build_selection_fields(
          meta,
          session,
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
            "where" =>
              predicate = build_bool_exp(
                meta,
                session,
                rel.target_model,
                relationships,
                arg.value,
              )
            "order_by" =>
              order_by = Some(
                build_order_by(
                  meta,
                  session,
                  rel.target_model,
                  relationships,
                  arg.value,
                ),
              )
            "limit" => limit = Some(arg.value.as_int_u32())
            "offset" => offset = Some(arg.value.as_int_u32())
            other => raise IrInternal("unknown argument: \{other}")
          }
        }
        match rel.kind {
          RelObject => limit = Some(1)
          RelArray => ()
        }
        let predicate = apply_permission_filter(
          meta,
          session,
          rel.target_model,
          predicate,
        )
        fields[alias_] = FRelationship(
          query={
            fields: Some(sub_fields),
            aggregates: None,
            limit,
            offset,
            predicate,
            order_by,
          },
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
pub fn build_bool_exp(
  meta : @metadata.Metadata,
  session : @session.Session,
  model_name : String,
  relationships : Map[String, @sqlgen.NdcRelationship],
  value : @schema.NValue,
) -> @sqlgen.NdcExpression? raise {
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
                  match
                    build_bool_exp(
                      meta, session, model_name, relationships, item,
                    ) {
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
                match
                  build_bool_exp(
                    meta,
                    session,
                    model_name,
                    relationships,
                    f.value,
                  ) {
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
          InputArg(BoolExpRelationship(rel_name)) => {
            if f.value.is_null() {
              continue
            }
            // リレーションを跨ぐ条件は exists に変換する
            // (object: 関連行が条件を満たす / array: 条件を満たす関連行が存在する)。
            // 対象モデルのロール行フィルタも exists 内に AND する
            let rel = lookup_relationship_def(meta, model_name, rel_name)
            let ndc_rel_name = register_ndc_relationship(
              meta, model_name, rel_name, rel, relationships,
            )
            let inner = build_bool_exp(
              meta,
              session,
              rel.target_model,
              relationships,
              f.value,
            )
            let inner = apply_permission_filter(
              meta,
              session,
              rel.target_model,
              inner,
            )
            conditions.push(
              EExistsRelated(
                relationship=ndc_rel_name,
                arguments=Map([]),
                predicate=inner,
              ),
            )
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
/// order_by の正規化済み値 → NDC order by。
/// リレーションフィールドは path (NdcPathElement) に変換し、対象モデルの
/// 行フィルタを path の predicate として注入する
fn build_order_by(
  meta : @metadata.Metadata,
  session : @session.Session,
  model_name : String,
  relationships : Map[String, @sqlgen.NdcRelationship],
  value : @schema.NValue,
) -> Array[@sqlgen.NdcOrderByElement] raise {
  let out : Array[@sqlgen.NdcOrderByElement] = []
  match value {
    List(items) =>
      for item in items {
        build_order_by_object(
          meta,
          session,
          model_name,
          relationships,
          item.as_object_value(),
          [],
          out,
        )
      }
    SimpleValue(NNull) => ()
    _ => raise IrInternal("order_by must be a list")
  }
  out
}

///|
fn build_order_by_object(
  meta : @metadata.Metadata,
  session : @session.Session,
  model_name : String,
  relationships : Map[String, @sqlgen.NdcRelationship],
  obj : Map[@graphql.Name, @schema.NInputField],
  path : Array[@sqlgen.NdcPathElement],
  out : Array[@sqlgen.NdcOrderByElement],
) -> Unit raise {
  // V3 準拠: 1 つの order_by 入力オブジェクトはちょうど 1 キー。
  // 複数キーはマップの順序が保証されずソート順が非決定的になるため拒否する
  // (V3 も 2024-12-10 以降エラーにする)。キーは配列側で並べる
  if obj.length() != 1 {
    raise IrBadRequest(
      "each order_by entry must specify exactly one field or relationship",
    )
  }
  for _, f in obj {
    match f.info.generic {
      InputArg(OrderByField(field_name)) => {
        let direction = match f.value {
          SimpleValue(NEnum(name~, ..)) => order_direction_of(name.as_str())
          _ => raise IrInternal("order_by value must be enum")
        }
        out.push({
          order_direction: direction,
          target_name: field_name,
          target_path: path.copy(),
        })
      }
      InputArg(OrderByRelationship(rel_name)) => {
        let rel = lookup_relationship_def(meta, model_name, rel_name)
        let ndc_rel_name = register_ndc_relationship(
          meta, model_name, rel_name, rel, relationships,
        )
        // 対象モデルの行フィルタを経路の predicate として適用する
        let predicate = apply_permission_filter(
          meta,
          session,
          rel.target_model,
          None,
        )
        let element : @sqlgen.NdcPathElement = {
          relationship: ndc_rel_name,
          arguments: Map([]),
          predicate,
        }
        let new_path = path.copy()
        new_path.push(element)
        build_order_by_object(
          meta,
          session,
          rel.target_model,
          relationships,
          f.value.as_object_value(),
          new_path,
          out,
        )
      }
      _ => raise IrInternal("unexpected order_by field")
    }
  }
}

///|
/// V3 の方向 enum (Asc / Desc) を NDC の order_direction (asc / desc) に変換する
fn order_direction_of(name : String) -> String raise {
  match name {
    "Asc" => "asc"
    "Desc" => "desc"
    other => raise IrBadRequest("invalid order_by direction: \{other}")
  }
}
