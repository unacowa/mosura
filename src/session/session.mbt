// セッション解決 (M5): ロールとセッション変数 (x-hasura-*)
// 開発モード認証: x-hasura-admin-secret 一致で x-hasura-role / x-hasura-* を信頼する

///|
pub(all) struct Session {
  role : String
  variables : Map[String, String]
}

///|
pub fn Session::admin() -> Session {
  { role: "admin", variables: Map([]) }
}

///|
pub fn Session::is_admin(self : Session) -> Bool {
  self.role == "admin"
}

///|
pub suberror AuthError {
  Unauthorized(String)
} derive(Debug)

///|
/// リクエストヘッダからセッションを解決する。
/// - AuthConfig なし: 常に admin (開発モード)
/// - adminSecret あり: x-hasura-admin-secret が一致した場合のみ
///   x-hasura-role (既定 admin) と x-hasura-* 変数を信頼する。不一致は拒否
pub fn resolve_session(
  auth : @metadata.AuthConfig?,
  headers : Map[String, String],
) -> Session raise AuthError {
  // ヘッダ名は小文字化して扱う
  let h : Map[String, String] = Map([])
  for k, v in headers {
    h[k.to_lower()] = v
  }
  match auth {
    None => Session::admin()
    Some(config) =>
      match config.admin_secret {
        Some(secret) =>
          match h.get("x-hasura-admin-secret") {
            Some(provided) =>
              if provided == secret {
                let role = match h.get("x-hasura-role") {
                  Some(r) => r
                  None => "admin"
                }
                let variables : Map[String, String] = Map([])
                for k, v in h {
                  if k.has_prefix("x-hasura-") &&
                    k != "x-hasura-admin-secret" &&
                    k != "x-hasura-role" {
                    variables[k] = v
                  }
                }
                { role, variables }
              } else {
                raise Unauthorized("invalid admin secret")
              }
            None => raise Unauthorized("missing x-hasura-admin-secret header")
          }
        None => Session::admin()
      }
  }
}
