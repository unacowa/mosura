// moonbit-community/postgres による SqlExecutor 実装 (native 専用)

///|
pub(all) struct NativeExecutor {
  client : @client.Client
}

///|
/// 接続を確立する。返された Connection の run() を呼び出し側の task group で
/// spawn_bg すること (プロトコル処理はそのタスクが担う)
pub async fn NativeExecutor::connect(
  config : @client.Config,
) -> (NativeExecutor, @client.Connection) {
  let (client, connection) = @client.connect(config)
  ({ client, }, connection)
}

///|
pub impl @exec.SqlExecutor for NativeExecutor with fn execute_json(
  self,
  sql,
  params,
) {
  let sql_params : Array[&@client.ToSql] = []
  for p in params {
    match p {
      PString(s) => sql_params.push(s)
      PValue(j) => sql_params.push(j.stringify())
      PVariable(_) =>
        raise @exec.ExecFailed("variables are not supported in this executor")
    }
  }
  let rows = self.client.query(sql, params=sql_params).collect()
  if rows.length() != 1 {
    raise @exec.ExecFailed("expected exactly one row, got \{rows.length()}")
  }
  let j : Json = rows[0].get(0)
  j.stringify()
}
