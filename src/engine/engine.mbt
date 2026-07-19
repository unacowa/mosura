// エンジン本体: GraphQL リクエスト → 実行 → GraphQL レスポンス。
// パース/正規化/計画は同期、SQL 実行のみ async (SqlExecutor 経由)。

///|
/// エンジンの静的コンテキスト (起動時に構築)
pub(all) struct EngineContext {
  meta : @metadata.Metadata
  schema : @schema.Schema
  pg_meta : @sqlgen.PgMetadata
}

///|
pub fn EngineContext::new(meta : @metadata.Metadata) -> EngineContext raise {
  let schema = @schemagen.build_schema(meta)
  let pg_meta = @ir.to_pg_metadata(meta)
  { meta, schema, pg_meta }
}

///|
/// GraphQL over HTTP のレスポンス (data / errors)
pub fn error_response(message : String) -> Json {
  let err : Map[String, Json] = { "message": Json::string(message) }
  let obj : Map[String, Json] = { "errors": Json::array([Json::object(err)]) }
  Json::object(obj)
}

///|
/// リクエスト JSON ({query, variables, operationName}) を処理する
pub async fn execute_request(
  ctx : EngineContext,
  ns : @schema.NamespaceCtx,
  executor : &@exec.SqlExecutor,
  body : Json,
) -> Json {
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
  let plan = @ir.plan_operation(ctx.meta, op) catch {
    e =>
      return error_response(
        match e {
          @ir.IrInternal(m) => "internal error: \{m}"
          @ir.UnsupportedField(f) => "unsupported field: \{f}"
          _ => "planning error"
        },
      )
  }

  // 5. 実行 + 整形
  let data : Map[String, Json] = Map([])
  for rf in plan {
    match rf {
      RFTypename(alias_~, type_name~) => data[alias_] = Json::string(type_name)
      RFSchema(alias_~, field~) => {
        let result = @schema.schema_type(ctx.schema, ns, field.selection_set) catch {
          _ => return error_response("introspection failed")
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
          _ => return error_response("introspection failed")
        }
        data[alias_] = result
      }
      RFQuery(alias_~, request~, shape~, selection~) => {
        let sql = @sqlgen.translate_query_request(ctx.pg_meta, request) catch {
          e => return error_response(e.display())
        }
        let universe_text = executor.execute_json(sql.sql, sql.params) catch {
          e =>
            return error_response(
              match e {
                @exec.ExecFailed(m) => "execution failed: \{m}"
                _ => "execution failed: \{e}"
              },
            )
        }
        let universe = @json.parse(universe_text) catch {
          _ => return error_response("invalid JSON from database")
        }
        // universe = [ { "rows": [...] } ] (variables なしの場合)
        let rows = extract_rows(universe)
        let shaped = shape_rows(
          ctx.meta,
          request.collection,
          selection,
          rows,
          shape,
        ) catch {
          e =>
            return error_response(
              match e {
                ShapeError(m) => "response shaping failed: \{m}"
                _ => "response shaping failed"
              },
            )
        }
        data[alias_] = shaped
      }
    }
  }
  let response : Map[String, Json] = { "data": Json::object(data) }
  Json::object(response)
}

///|
pub suberror ShapeError {
  ShapeError(String)
} derive(Debug)

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
) -> Json raise ShapeError {
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
    let fc = try? f.field_call()
    let fc = match fc {
      Ok(fc) => fc
      Err(_) => continue
    }
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
