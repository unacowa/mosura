// Hasura claims アダプタ: 検証済み JWT ペイロード → Session。
// JWT 検証コア (jwt.mbt) と分離しており、Hasura 固有のセマンティクスはここに集約する。
//
// 対応する claims 名前空間 (どちらかがあればよい):
// - V2 形式: "https://hasura.io/jwt/claims"
// - V3 形式: "claims.jwt.hasura.io"
// 名前空間内の x-hasura-default-role / x-hasura-allowed-roles は必須。
// その他の x-hasura-* キーはセッション変数になる。
// ロール切替: x-hasura-role ヘッダがあれば allowed-roles 内でのみ許可。

///|
const CLAIMS_NAMESPACE_V2 = "https://hasura.io/jwt/claims"

///|
const CLAIMS_NAMESPACE_V3 = "claims.jwt.hasura.io"

///|
/// JSON 値をセッション変数の文字列表現にする
fn claim_value_to_string(v : Json) -> String? {
  match v {
    Json::String(s) => Some(s)
    Json::Number(d, ..) =>
      if d == d.floor() {
        Some(d.to_int64().to_string())
      } else {
        Some(d.to_string())
      }
    Json::True => Some("true")
    Json::False => Some("false")
    _ => None
  }
}

///|
/// 検証済みペイロードから Hasura claims を抽出してセッションを作る
pub fn session_from_claims(
  payload : Json,
  role_header : String?,
) -> Session raise AuthError {
  let claims = match payload {
    Json::Object(p) =>
      match (p.get(CLAIMS_NAMESPACE_V3), p.get(CLAIMS_NAMESPACE_V2)) {
        (Some(Json::Object(c)), _) => c
        (_, Some(Json::Object(c))) => c
        _ =>
          raise Unauthorized(
            "invalid JWT: missing hasura claims namespace (\{CLAIMS_NAMESPACE_V2})",
          )
      }
    _ => raise Unauthorized("invalid JWT: payload is not an object")
  }
  let default_role = match claims.get("x-hasura-default-role") {
    Some(Json::String(r)) => r
    _ => raise Unauthorized("invalid JWT: missing x-hasura-default-role claim")
  }
  let allowed_roles : Array[String] = []
  match claims.get("x-hasura-allowed-roles") {
    Some(Json::Array(items)) =>
      for item in items {
        match item {
          Json::String(r) => allowed_roles.push(r)
          _ => ()
        }
      }
    _ => raise Unauthorized("invalid JWT: missing x-hasura-allowed-roles claim")
  }
  let role = match role_header {
    Some(requested) =>
      if allowed_roles.contains(requested) {
        requested
      } else {
        raise Unauthorized(
          "invalid x-hasura-role: \{requested} is not in allowed roles",
        )
      }
    None => default_role
  }
  let variables : Map[String, String] = Map([])
  for k, v in claims {
    let key = k.to_lower()
    if key.has_prefix("x-hasura-") &&
      key != "x-hasura-default-role" &&
      key != "x-hasura-allowed-roles" &&
      key != "x-hasura-role" {
      match claim_value_to_string(v) {
        Some(s) => variables[key] = s
        None => ()
      }
    }
  }
  { role, variables }
}
