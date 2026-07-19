///|
/// ロールとセッション変数 (x-hasura-*)。M5 で本実装、それまでは admin 固定。
pub struct Session {
  role : String
  variables : Map[String, String]
} derive(Debug)

///|
pub fn Session::admin() -> Session {
  { role: "admin", variables: Map([]) }
}
