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
/// - adminSecret あり + x-hasura-admin-secret ヘッダあり: 一致した場合のみ
///   x-hasura-role (既定 admin) と x-hasura-* 変数を信頼する。不一致は拒否
/// - jwtHs256Secret あり (admin-secret ヘッダなし): Authorization: Bearer の
///   JWT を検証し、Hasura claims からロールとセッション変数を得る。
///   x-hasura-role ヘッダによる切替は allowed-roles 内でのみ許可
/// - now_epoch_secs を与えると JWT の exp (epoch 秒) を検査する
pub fn resolve_session(
  auth : @metadata.AuthConfig?,
  headers : Map[String, String],
  now_epoch_secs? : Int64? = None,
) -> Session raise AuthError {
  // ヘッダ名は小文字化して扱う
  let h : Map[String, String] = Map([])
  for k, v in headers {
    h[k.to_lower()] = v
  }
  let config = match auth {
    None => return Session::admin()
    Some(config) => config
  }
  // 開発モード: admin-secret が設定され、ヘッダでも提示された場合
  match (config.admin_secret, h.get("x-hasura-admin-secret")) {
    (Some(secret), Some(provided)) =>
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
        return { role, variables }
      } else {
        raise Unauthorized("invalid admin secret")
      }
    _ => ()
  }
  // JWT モード
  match config.jwt_hs256_secret {
    Some(secret) => {
      let token = match h.get("authorization") {
        Some(value) =>
          if value.has_prefix("Bearer ") {
            value[7:].to_owned()
          } else {
            raise Unauthorized("Authorization header must use Bearer scheme")
          }
        None => raise Unauthorized("missing Authorization header")
      }
      let payload = verify_jwt_hs256(token, secret, now_epoch_secs~)
      return session_from_claims(payload, h.get("x-hasura-role"))
    }
    None => ()
  }
  match config.admin_secret {
    Some(_) => raise Unauthorized("missing x-hasura-admin-secret header")
    None => Session::admin()
  }
}
