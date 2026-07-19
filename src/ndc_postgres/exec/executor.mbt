///| SQL 実行トランスポートの抽象。実装はランタイムごとに差し替える:

///|
/// exec/native = moonbit-community/postgres (TCP 直結) / exec/workers = Hyperdrive + JS ドライバ (M7)
pub(open) trait SqlExecutor {
  ///| パラメタライズドクエリを実行し、text 形式の 1 カラム (JSON 組み立て済み) を行ごとに返す
  fn execute_json(Self, String, Array[String]) -> Array[String] raise
}
