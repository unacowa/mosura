// V3 engine execute フィクスチャの E2E 実行。
// V3 メタデータ (互換ローダ) + V3 のシード SQL (fixtures/execute-seed) を使い、
// request.gql をセッションごとに実行して expected.json と構造比較する。
//
// 実行できるのは Mosura の機能サブセット内のケースのみ。合格が確認された
// ケースは execute_passing_cases に固定し、回帰として検証する (追加は台帳参照)。

///|
/// 合格を固定したケース (fixtures/execute からの相対パス)
let execute_passing_cases : Array[String] = execute_passing_cases_list()

///|
fn read_json(path : String) -> Json raise {
  @json.parse(@fs.read_file_to_string(path))
}

///|
/// 数値表現 (repr) の違いを無視した構造比較
fn json_equal(a : Json, b : Json) -> Bool {
  match (a, b) {
    (Json::Null, Json::Null) => true
    (Json::True, Json::True) => true
    (Json::False, Json::False) => true
    (Json::Number(x, ..), Json::Number(y, ..)) => x == y
    (Json::String(x), Json::String(y)) => x == y
    (Json::Array(xs), Json::Array(ys)) => {
      if xs.length() != ys.length() {
        return false
      }
      for i in 0..<xs.length() {
        if !json_equal(xs[i], ys[i]) {
          return false
        }
      }
      true
    }
    (Json::Object(xm), Json::Object(ym)) => {
      if xm.length() != ym.length() {
        return false
      }
      for k, v in xm {
        match ym.get(k) {
          Some(w) => if !json_equal(v, w) { return false }
          None => return false
        }
      }
      true
    }
    _ => false
  }
}

///|
async fn seed_execute_fixtures(client : @client.Client) -> Unit {
  // 既にシード済みならスキップ (フィクスチャデータは静的)
  let rows = client
    .query("select to_regclass('public.article')::text as t")
    .collect()
  let existing : String? = rows[0].get(0)
  if existing is Some(_) {
    return
  }
  client.batch_execute(
    @fs.read_file_to_string("fixtures/execute-seed/db_definition.sql"),
  )
  client.batch_execute(
    @fs.read_file_to_string("fixtures/execute-seed/chinook-postgres.sql"),
  )
}

///|
priv enum CaseResult {
  CasePass
  CaseFail(String)
  CaseSkip(String)
}

///|
async fn run_execute_case(
  executor : @native.NativeExecutor,
  dir : String,
) -> CaseResult {
  // メタデータ
  let meta_json = read_json("\{dir}/metadata.json") catch {
    _ => return CaseSkip("no/invalid metadata.json")
  }
  let loaded = @metadata.load_v3_metadata(meta_json, auto_stub_connectors=true) catch {
    e => return CaseSkip("metadata: \{e.display()}")
  }
  let ctx = @engine.EngineContext::new(loaded.metadata) catch {
    _ => return CaseSkip("schema build failed")
  }
  let query = @fs.read_file_to_string("\{dir}/request.gql") catch {
    _ => return CaseSkip("no request.gql")
  }
  let sessions_json = read_json("\{dir}/session_variables.json") catch {
    _ => return CaseSkip("no session_variables.json")
  }
  let sessions : Array[Json] = match sessions_json {
    Json::Array(items) => items
    _ => return CaseSkip("session_variables must be an array")
  }
  let variables : Json? = if @fs.path_exists("\{dir}/variables.json") {
    let v = read_json("\{dir}/variables.json") catch { _ => Json::null() }
    match v {
      Json::Null => None
      other => Some(other)
    }
  } else {
    None
  }
  let expected = read_json("\{dir}/expected.json") catch {
    _ => return CaseSkip("no expected.json")
  }
  let expected_list : Array[Json] = match expected {
    Json::Array(items) => items
    other => [other]
  }
  if expected_list.length() != sessions.length() {
    return CaseSkip("session/expected count mismatch")
  }
  // セッションごとに実行
  for i in 0..<sessions.length() {
    let session_obj = sessions[i]
    let mut role = "admin"
    let vars : Map[String, String] = Map([])
    match session_obj {
      Json::Object(m) =>
        for k, v in m {
          let key = k.to_lower()
          let value = match v {
            Json::String(s) => s
            Json::Number(d, ..) =>
              if d == d.floor() {
                d.to_int64().to_string()
              } else {
                d.to_string()
              }
            Json::True => "true"
            Json::False => "false"
            _ => continue
          }
          if key == "x-hasura-role" {
            role = value
          } else {
            vars[key] = value
          }
        }
      _ => ()
    }
    let session : @session.Session = { role, variables: vars }
    let body : Map[String, Json] = { "query": Json::string(query) }
    match variables {
      Some(v) => body["variables"] = v
      None => ()
    }
    let response = @engine.execute_request(
      ctx,
      session,
      executor,
      Json::object(body),
    )
    if !json_equal(response, expected_list[i]) {
      return CaseFail("session \{i}: response mismatch")
    }
  }
  CasePass
}

///|
fn list_execute_case_dirs() -> Array[String] raise {
  let out : Array[String] = []
  fn walk(dir : String) -> Unit raise {
    if @fs.path_exists("\{dir}/request.gql") &&
      @fs.path_exists("\{dir}/metadata.json") &&
      @fs.path_exists("\{dir}/expected.json") {
      out.push(dir)
    }
    let entries = @fs.read_dir(dir)
    entries.sort()
    for e in entries {
      if @fs.is_dir("\{dir}/\{e}") {
        walk("\{dir}/\{e}")
      }
    }
  }
  walk("fixtures/execute")
  out
}

///|
async test "execute フィクスチャ: 固定ケースの回帰 + 全体の実態把握" {
  let mut passed = 0
  let mut failed_pinned = 0
  let all_pass : Array[String] = []
  @async.with_task_group(group => {
    let config = @client.Config::new(
      pg_host(),
      port=pg_port(),
      user=pg_user(),
      database=pg_database(),
      password=pg_password(),
      ssl_mode=@client.SslMode::Disable,
      application_name="mosura-execute-fixtures",
    )
    let (executor, connection) = @native.NativeExecutor::connect(config)
    group.spawn_bg(() => connection.run())
    seed_execute_fixtures(executor.client)
    let dirs = list_execute_case_dirs()
    for dir in dirs {
      let rel = dir["fixtures/execute/".length():].to_owned()
      let result = run_execute_case(executor, dir)
      match result {
        CasePass => {
          passed += 1
          all_pass.push(rel)
        }
        CaseFail(msg) =>
          if execute_passing_cases.contains(rel) {
            println("PINNED-FAIL \{rel}: \{msg}")
            failed_pinned += 1
          }
        CaseSkip(msg) =>
          if execute_passing_cases.contains(rel) {
            println("PINNED-SKIP \{rel}: \{msg}")
            failed_pinned += 1
          }
      }
    }
    executor.client.close()
  })
  println(
    "execute fixtures: total-pass=\{passed} pinned=\{execute_passing_cases.length()}",
  )
  for p in all_pass {
    println("  PASS \{p}")
  }
  // 固定したケースは必ず通ること
  assert_eq(failed_pinned, 0)
  // 固定リスト外で新たに通るようになったケースは台帳更新を促す
  for p in all_pass {
    if !execute_passing_cases.contains(p) {
      println("  NEW-PASS (add to pinned list): \{p}")
    }
  }
  assert_true(passed >= execute_passing_cases.length())
}
