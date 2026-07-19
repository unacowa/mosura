// SQL 実行トランスポートの抽象。
// 実装はランタイムごとに差し替える:
//   exec/native  = moonbit-community/postgres (TCP 直結)
//   exec/workers = Hyperdrive + JS ドライバ (M7)

///|
pub(all) suberror ExecError {
  ExecFailed(String)
} derive(Debug)

///|
pub(open) trait SqlExecutor {
  /// パラメタライズドクエリを実行し、単一行単一カラム (JSON 組み立て済み) をテキストで返す
  async fn execute_json(Self, String, Array[@sqlgen.Param]) -> String
}
