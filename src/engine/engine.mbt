// エンジン本体: GraphQL リクエスト → 実行 → GraphQL レスポンス。
// パース/正規化/計画は同期、SQL 実行のみ async (SqlExecutor 経由)。

///|
/// エンジンの静的コンテキスト (起動時に構築)
pub(all) struct EngineContext {
  meta : @metadata.Metadata
  schema : @schema.Schema
  pg_meta : @sqlgen.PgMetadata
  /// 内部エラーの詳細をクライアントに含めるか。既定は false (本番安全側)。
  /// V3 は内部エラーを "internal error" のみで返すため既定で秘匿する。
  /// 開発時のみ true にして原因究明を容易にする。
  expose_internal_errors : Bool
}

///|
pub fn EngineContext::new(
  meta : @metadata.Metadata,
  expose_internal_errors? : Bool = false,
) -> EngineContext raise {
  let schema = @schemagen.build_schema(meta)
  let pg_meta = @ir.to_pg_metadata(meta)
  { meta, schema, pg_meta, expose_internal_errors }
}

///|
/// GraphQL over HTTP のレスポンス (data / errors)
pub fn error_response(message : String) -> Json {
  let err : Map[String, Json] = { "message": Json::string(message) }
  let obj : Map[String, Json] = { "errors": Json::array([Json::object(err)]) }
  Json::object(obj)
}

///|
/// 内部エラー応答を組み立てる。V3 準拠で本番 (expose=false) では詳細を秘匿し
/// "internal error" のみ返す。expose=true (開発時) のときだけ detail を含める。
/// detail は DB エラー文・スキーマ情報を含み得るため、本番では決して露出しない。
/// 呼び出し側は expose の値に関わらず detail をログ/トレースへ残すこと。
pub fn internal_error_json(expose : Bool, detail : String) -> Json {
  if expose {
    error_response("internal error: \{detail}")
  } else {
    error_response("internal error")
  }
}

///|
/// ctx の設定に従って内部エラー応答を返す
fn EngineContext::internal_error(self : EngineContext, detail : String) -> Json {
  internal_error_json(self.expose_internal_errors, detail)
}

///|
/// リクエスト JSON ({query, variables, operationName}) を処理する
pub async fn execute_request(
  ctx : EngineContext,
  session : @session.Session,
  executor : &@exec.SqlExecutor,
  body : Json,
) -> Json {
  let ns : @schema.NamespaceCtx = if session.is_admin() {
    AllowAll
  } else {
    Role(session.role)
  }
  // 1. リクエストの分解
  let query_text = match body {
    Json::Object(m) =>
      match m.get("query") {
        Some(Json::String(q)) => q
        _ => return error_response("missing 'query' in request body")
      }
    _ => return error_response("request body must be a JSON object")
  }
  let variables : Map[String, Json] = Map([])
  match body {
    Json::Object(m) =>
      match m.get("variables") {
        Some(Json::Object(vm)) =>
          for k, v in vm {
            variables[k] = v
          }
        _ => ()
      }
    _ => ()
  }
  let operation_name : @graphql.Name? = match body {
    Json::Object(m) =>
      match m.get("operationName") {
        Some(Json::String(n)) =>
          if @graphql.is_valid_graphql_name(n) {
            Some(@graphql.Name::new_unchecked(n))
          } else {
            None
          }
        _ => None
      }
    _ => None
  }

  // 2. パース
  let parser = @graphql.Parser::new(@utf8.encode(query_text))
  let doc = parser.parse_executable_document() catch {
    @graphql.ParseErr(p) => return error_response(p.item.display())
  }

  // 3. 正規化 (バリデーション込み)
  let op = @schema.normalize_request(ns, ctx.schema, {
    query: doc,
    operation_name,
    variables,
  }) catch {
    e => return error_response(e.display())
  }

  // 4. 実行計画
  let plan = @ir.plan_operation(ctx.meta, ctx.pg_meta, session, op) catch {
    e =>
      // ユーザー起因 (権限・不正リクエスト・未対応フィールド) はメッセージを返し、
      // 内部エラーは秘匿する (V3 準拠)
      return match e {
        @ir.IrPermissionDenied(m) => error_response(m)
        @ir.IrBadRequest(m) => error_response(m)
        @ir.UnsupportedField(f) => error_response("unsupported field: \{f}")
        @ir.IrInternal(m) => ctx.internal_error("planning: \{m}")
        _ => ctx.internal_error("planning error")
      }
  }

  // 5. 実行 + 整形。ミューテーションを含むリクエストは 1 トランザクションで
  // 実行し、エラー・post-write CHECK 違反時は全体を ROLLBACK する (#18)
  let mut in_tx = false
  for rf in plan {
    match rf {
      RFMutation(..) => in_tx = true
      _ => ()
    }
  }
  if in_tx {
    executor.execute_command("BEGIN ISOLATION LEVEL READ COMMITTED") catch {
      _ => return ctx.internal_error("failed to begin transaction")
    }
  }
  let data : Map[String, Json] = Map([])
  for rf in plan {
    match rf {
      RFTypename(alias_~, type_name~) => data[alias_] = Json::string(type_name)
      RFSchema(alias_~, field~) => {
        let result = @schema.schema_type(ctx.schema, ns, field.selection_set) catch {
          _ => {
            rollback_if(executor, in_tx)
            return ctx.internal_error("introspection failed")
          }
        }
        data[alias_] = result
      }
      RFType(alias_~, field~, type_name~) => {
        if !@graphql.is_valid_graphql_name(type_name) {
          data[alias_] = Json::null()
          continue
        }
        let tn = @graphql.TypeName(@graphql.Name::new_unchecked(type_name))
        let result = @schema.type_lookup(
          ctx.schema,
          ns,
          tn,
          field.selection_set,
        ) catch {
          _ => {
            rollback_if(executor, in_tx)
            return ctx.internal_error("introspection failed")
          }
        }
        data[alias_] = result
      }
      RFMutation(alias_~, sql~, model~, kind~, selection~) => {
        let rows_text = executor.execute_json(sql.sql, sql.params) catch {
          e => {
            rollback_if(executor, in_tx)
            return ctx.internal_error(
              match e {
                @exec.ExecFailed(m) => "execution failed: \{m}"
                _ => "execution failed: \{e}"
              },
            )
          }
        }
        let rows_json = @json.parse(rows_text) catch {
          _ => {
            rollback_if(executor, in_tx)
            return ctx.internal_error("invalid JSON from database")
          }
        }
        let rows = match rows_json {
          Json::Array(rs) => rs
          _ => []
        }
        // post-write 権限 CHECK: 書き込み後の行に違反フラグが 1 つでもあれば
        // リクエスト全体を拒否してロールバックする
        let mut violated = false
        for r in rows {
          match r {
            Json::Object(m) =>
              match m.get(@sqlgen.check_violation_field) {
                Some(Json::True) => violated = true
                _ => ()
              }
            _ => ()
          }
        }
        if violated {
          rollback_if(executor, in_tx)
          return error_response(
            "check constraint of an insert/update permission has failed",
          )
        }
        data[alias_] = shape_mutation(ctx.meta, model, kind, selection, rows)
      }
      RFQuery(alias_~, request~, shape~, selection~) => {
        let sql = @sqlgen.translate_query_request(ctx.pg_meta, request) catch {
          e => {
            rollback_if(executor, in_tx)
            return ctx.internal_error(e.display())
          }
        }
        let universe_text = executor.execute_json(sql.sql, sql.params) catch {
          e => {
            rollback_if(executor, in_tx)
            return ctx.internal_error(
              match e {
                @exec.ExecFailed(m) => "execution failed: \{m}"
                _ => "execution failed: \{e}"
              },
            )
          }
        }
        let universe = @json.parse(universe_text) catch {
          _ => {
            rollback_if(executor, in_tx)
            return ctx.internal_error("invalid JSON from database")
          }
        }
        // universe = [ { "rows": [...] } ] (variables なしの場合)
        let rows = extract_rows(universe)
        data[alias_] = shape_rows(
          ctx.meta,
          request.collection,
          selection,
          rows,
          shape,
        )
      }
    }
  }
  if in_tx {
    executor.execute_command("COMMIT") catch {
      _ => {
        rollback_if(executor, true)
        return ctx.internal_error("failed to commit transaction")
      }
    }
  }
  let response : Map[String, Json] = { "data": Json::object(data) }
  Json::object(response)
}

///|
/// トランザクション中のエラー時に ROLLBACK する。ROLLBACK 自体の失敗は
/// 握りつぶす (元のエラーを応答することを優先。接続破棄で整合は保たれる)
async fn rollback_if(executor : &@exec.SqlExecutor, in_tx : Bool) -> Unit {
  if in_tx {
    executor.execute_command("ROLLBACK") catch {
      _ => ()
    }
  }
}

///|
/// universe JSON から rows 配列を取り出す
fn extract_rows(universe : Json) -> Array[Json] {
  match universe {
    Json::Array([Json::Object(m), ..]) =>
      match m.get("rows") {
        Some(Json::Array(rows)) => rows
        _ => []
      }
    _ => []
  }
}

///|
/// DB の行 JSON を GraphQL 応答形状に整形する
/// - __typename の挿入
/// - リレーションフィールドの {rows: [...]} を object/array に展開
fn shape_rows(
  meta : @metadata.Metadata,
  model_name : String,
  selection : @schema.NSelectionSet,
  rows : Array[Json],
  shape : @ir.ResponseShape,
) -> Json {
  let shaped_rows = rows.map(row => shape_row(meta, model_name, selection, row))
  // map の中で raise できないため二段階でチェック
  let out : Array[Json] = []
  for r in shaped_rows {
    out.push(r)
  }
  match shape {
    ShapeList => Json::array(out)
    ShapeObject => if out.is_empty() { Json::null() } else { out[0] }
  }
}

///|
fn shape_row(
  meta : @metadata.Metadata,
  model_name : String,
  selection : @schema.NSelectionSet,
  row : Json,
) -> Json {
  let row_map = match row {
    Json::Object(m) => m
    other => return other
  }
  let model = meta.models.get(model_name).unwrap()
  let out : Map[String, Json] = Map([])
  for _, f in selection.fields {
    let alias_ = f.nalias.0.as_str()
    let fc = f.field_call() catch { _ => continue }
    match fc.info.generic {
      Introspection =>
        if fc.name.as_str() == "__typename" {
          let ot = meta.object_types.get(model.object_type).unwrap()
          out[alias_] = Json::string(ot.graphql_type_name)
        }
      ModelField(_) =>
        out[alias_] = match row_map.get(alias_) {
          Some(v) => v
          None => Json::null()
        }
      RelationshipField(rel_name) => {
        // リレーション値は {"rows": [...]} 形式
        let rels = meta.relationships.get(model.object_type).unwrap()
        let mut rel : @metadata.Relationship? = None
        for r in rels {
          if r.name == rel_name {
            rel = Some(r)
          }
        }
        let rel = rel.unwrap()
        let inner_rows : Array[Json] = match row_map.get(alias_) {
          Some(Json::Object(m)) =>
            match m.get("rows") {
              Some(Json::Array(rs)) => rs
              _ => []
            }
          _ => []
        }
        let shaped = inner_rows.map(r => {
          shape_row(meta, rel.target_model, f.selection_set, r)
        })
        out[alias_] = match rel.kind {
          RelArray => Json::array(shaped)
          RelObject => if shaped.is_empty() { Json::null() } else { shaped[0] }
        }
      }
      _ => ()
    }
  }
  Json::object(out)
}

///|
/// ミューテーション結果の整形
fn shape_mutation(
  meta : @metadata.Metadata,
  model_name : String,
  kind : @ir.MutationKind,
  selection : @schema.NSelectionSet,
  rows : Array[Json],
) -> Json {
  match kind {
    MInsert => {
      // mutation_response: affected_rows / returning / __typename
      let out : Map[String, Json] = Map([])
      for _, f in selection.fields {
        let alias_ = f.nalias.0.as_str()
        let fc = f.field_call() catch { _ => continue }
        match fc.info.generic {
          AffectedRows => out[alias_] = Json::number(rows.length().to_double())
          ReturningRows(_) => {
            let shaped = rows.map(r => {
              shape_row(meta, model_name, f.selection_set, r)
            })
            out[alias_] = Json::array(shaped)
          }
          Introspection => {
            let ot_name = meta.object_types
              .get(meta.models.get(model_name).unwrap().object_type)
              .unwrap().graphql_type_name
            out[alias_] = Json::string("\{ot_name}_mutation_response")
          }
          _ => ()
        }
      }
      Json::object(out)
    }
    MUpdateByPk | MDeleteByPk =>
      if rows.is_empty() {
        Json::null()
      } else {
        shape_row(meta, model_name, selection, rows[0])
      }
  }
}

///|
/// 実行フェーズに渡す計画。resolved は SQL 実行なしで確定した値 (introspection 等)
pub(all) struct PlannedRequest {
  /// SQL 実行が必要なルートフィールド (実行順)
  queries : Array[PlannedQuery]
  /// SQL 不要で確定済みの data エントリ
  resolved : Map[String, Json]
  /// data のキー順 (GraphQL はフィールド順を保持する)
  order : Array[String]
}

///|
pub(all) struct PlannedQuery {
  alias_ : String
  sql : String
  params : Array[@sqlgen.Param]
  root : @ir.RootField
}

///|
/// リクエストを計画する (純粋・同期)。エラー時は Err(GraphQL エラーレスポンス)
pub fn plan_request(
  ctx : EngineContext,
  session : @session.Session,
  body : Json,
) -> Result[PlannedRequest, Json] {
  let ns : @schema.NamespaceCtx = if session.is_admin() {
    AllowAll
  } else {
    Role(session.role)
  }
  let query_text = match body {
    Json::Object(m) =>
      match m.get("query") {
        Some(Json::String(q)) => q
        _ => return Err(error_response("missing 'query' in request body"))
      }
    _ => return Err(error_response("request body must be a JSON object"))
  }
  let variables : Map[String, Json] = Map([])
  match body {
    Json::Object(m) =>
      match m.get("variables") {
        Some(Json::Object(vm)) =>
          for k, v in vm {
            variables[k] = v
          }
        _ => ()
      }
    _ => ()
  }
  let operation_name : @graphql.Name? = match body {
    Json::Object(m) =>
      match m.get("operationName") {
        Some(Json::String(n)) =>
          if @graphql.is_valid_graphql_name(n) {
            Some(@graphql.Name::new_unchecked(n))
          } else {
            None
          }
        _ => None
      }
    _ => None
  }
  let parser = @graphql.Parser::new(@utf8.encode(query_text))
  let doc = parser.parse_executable_document() catch {
    @graphql.ParseErr(p) => return Err(error_response(p.item.display()))
  }
  let op = @schema.normalize_request(ns, ctx.schema, {
    query: doc,
    operation_name,
    variables,
  }) catch {
    e => return Err(error_response(e.display()))
  }
  let plan = @ir.plan_operation(ctx.meta, ctx.pg_meta, session, op) catch {
    e =>
      return Err(
        match e {
          @ir.IrPermissionDenied(m) => error_response(m)
          @ir.IrBadRequest(m) => error_response(m)
          @ir.UnsupportedField(f) => error_response("unsupported field: \{f}")
          @ir.IrInternal(m) => ctx.internal_error("planning: \{m}")
          _ => ctx.internal_error("planning error")
        },
      )
  }
  let queries : Array[PlannedQuery] = []
  let resolved : Map[String, Json] = Map([])
  let order : Array[String] = []
  for rf in plan {
    match rf {
      RFTypename(alias_~, type_name~) => {
        resolved[alias_] = Json::string(type_name)
        order.push(alias_)
      }
      RFSchema(alias_~, field~) => {
        let result = @schema.schema_type(ctx.schema, ns, field.selection_set) catch {
          _ => return Err(ctx.internal_error("introspection failed"))
        }
        resolved[alias_] = result
        order.push(alias_)
      }
      RFType(alias_~, field~, type_name~) => {
        if !@graphql.is_valid_graphql_name(type_name) {
          resolved[alias_] = Json::null()
          order.push(alias_)
          continue
        }
        let tn = @graphql.TypeName(@graphql.Name::new_unchecked(type_name))
        let result = @schema.type_lookup(
          ctx.schema,
          ns,
          tn,
          field.selection_set,
        ) catch {
          _ => return Err(ctx.internal_error("introspection failed"))
        }
        resolved[alias_] = result
        order.push(alias_)
      }
      RFQuery(alias_~, request~, ..) => {
        let sql = @sqlgen.translate_query_request(ctx.pg_meta, request) catch {
          e => return Err(ctx.internal_error(e.display()))
        }
        queries.push({ alias_, sql: sql.sql, params: sql.params, root: rf })
        order.push(alias_)
      }
      RFMutation(alias_~, sql~, ..) => {
        queries.push({ alias_, sql: sql.sql, params: sql.params, root: rf })
        order.push(alias_)
      }
    }
  }
  Ok({ queries, resolved, order })
}

///|
/// 実行結果 (alias → DB が返した JSON) を最終レスポンスに整形する
pub fn shape_results(
  ctx : EngineContext,
  planned : PlannedRequest,
  results : Map[String, Json],
) -> Json {
  let data : Map[String, Json] = Map([])
  for alias_ in planned.order {
    match planned.resolved.get(alias_) {
      Some(v) => {
        data[alias_] = v
        continue
      }
      None => ()
    }
    let mut pq : PlannedQuery? = None
    for q in planned.queries {
      if q.alias_ == alias_ {
        pq = Some(q)
      }
    }
    let pq = match pq {
      Some(q) => q
      None => continue
    }
    let result_json = match results.get(alias_) {
      Some(r) => r
      None => Json::null()
    }
    match pq.root {
      RFQuery(request~, shape~, selection~, ..) => {
        let rows = extract_rows(result_json)
        data[alias_] = shape_rows(
          ctx.meta,
          request.collection,
          selection,
          rows,
          shape,
        )
      }
      RFMutation(model~, kind~, selection~, ..) => {
        let rows = match result_json {
          Json::Array(rs) => rs
          _ => []
        }
        data[alias_] = shape_mutation(ctx.meta, model, kind, selection, rows)
      }
      _ => ()
    }
  }
  let response : Map[String, Json] = { "data": Json::object(data) }
  Json::object(response)
}
