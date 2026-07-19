// Cloudflare Workers 向けの純粋 2 フェーズ API (js ターゲット)。
// SQL の実行は Workers 側 JS グルー (postgres.js + Hyperdrive) が担い、
// MoonBit 側は plan (GraphQL → SQL 群) と shape (実行結果 → レスポンス) のみを行う。
//
// JS からの呼び出し:
//   const plan = JSON.parse(mosura_plan(metadataYaml, bodyJson, role, sessionVarsJson))
//   //   plan = {queries: [{alias, sql, params: [...]}, ...]} または {errors: [...]}
//   // 各 sql を実行して {alias: <1行1列のJSON>} を集める
//   const response = mosura_shape(metadataYaml, bodyJson, role, sessionVarsJson, resultsJson)

///|
fn build_session(role : String, session_vars_json : String) -> @session.Session {
  let variables : Map[String, String] = Map([])
  match (try? @json.parse(session_vars_json)) {
    Ok(Json::Object(m)) =>
      for k, v in m {
        match v {
          Json::String(s) => variables[k.to_lower()] = s
          _ => ()
        }
      }
    _ => ()
  }
  { role, variables }
}

///|
fn error_json(message : String) -> String {
  @engine.error_response(message).stringify()
}

///|
fn param_to_json(p : @sqlgen.Param) -> Json {
  match p {
    PString(s) => Json::string(s)
    PValue(j) => Json::string(j.stringify())
    PVariable(v) => Json::string(v)
  }
}

///|
/// フェーズ 1: リクエストを計画し、実行すべき SQL 群を返す
pub fn mosura_plan(
  metadata_yaml : String,
  body_json : String,
  role : String,
  session_vars_json : String,
) -> String {
  let meta = @metadata.load_yaml(metadata_yaml) catch {
    e => return error_json(e.display())
  }
  let ctx = @engine.EngineContext::new(meta) catch {
    _ => return error_json("failed to build schema")
  }
  let body = @json.parse(body_json) catch {
    _ => return error_json("request body is not valid JSON")
  }
  let session = build_session(role, session_vars_json)
  match @engine.plan_request(ctx, session, body) {
    Err(err_response) => err_response.stringify()
    Ok(planned) => {
      let queries : Array[Json] = []
      for q in planned.queries {
        let entry : Map[String, Json] = {
          "alias": Json::string(q.alias_),
          "sql": Json::string(q.sql),
          "params": Json::array(q.params.map(p => param_to_json(p))),
        }
        queries.push(Json::object(entry))
      }
      let out : Map[String, Json] = { "queries": Json::array(queries) }
      Json::object(out).stringify()
    }
  }
}

///|
/// フェーズ 2: 実行結果 (alias → 1行1列の JSON テキスト) からレスポンスを整形する
pub fn mosura_shape(
  metadata_yaml : String,
  body_json : String,
  role : String,
  session_vars_json : String,
  results_json : String,
) -> String {
  let meta = @metadata.load_yaml(metadata_yaml) catch {
    e => return error_json(e.display())
  }
  let ctx = @engine.EngineContext::new(meta) catch {
    _ => return error_json("failed to build schema")
  }
  let body = @json.parse(body_json) catch {
    _ => return error_json("request body is not valid JSON")
  }
  let session = build_session(role, session_vars_json)
  let planned = match @engine.plan_request(ctx, session, body) {
    Err(err_response) => return err_response.stringify()
    Ok(p) => p
  }
  let results : Map[String, Json] = Map([])
  match (try? @json.parse(results_json)) {
    Ok(Json::Object(m)) =>
      for alias_, v in m {
        // 値は JSON テキスト (文字列) か、すでにパース済みの JSON を許容
        match v {
          Json::String(text) =>
            match (try? @json.parse(text)) {
              Ok(parsed) => results[alias_] = parsed
              Err(_) => results[alias_] = Json::null()
            }
          other => results[alias_] = other
        }
      }
    _ => return error_json("results must be a JSON object")
  }
  @engine.shape_results(ctx, planned, results).stringify()
}
