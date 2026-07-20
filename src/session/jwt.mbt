// JWT (HS256) の検証と Hasura claims の抽出 (M5)
//
// 対応する claims 形式 (どちらかがあればよい):
// - V2 形式: ペイロードの "https://hasura.io/jwt/claims" 名前空間
// - V3 形式: ペイロードの "claims.jwt.hasura.io" 名前空間
// 名前空間内の x-hasura-default-role / x-hasura-allowed-roles は必須。
// その他の x-hasura-* キーはセッション変数になる。
//
// ロール切替: x-hasura-role ヘッダがあれば allowed-roles 内でのみ許可。
// 無ければ default-role を使う。
// exp / nbf (epoch 秒) は now_epoch_secs が与えられた場合のみ検査する。
// このパッケージは pure (時刻を取得しない) ため now は必須引数で呼び出し側が渡す。

///|
const CLAIMS_NAMESPACE_V2 = "https://hasura.io/jwt/claims"

///|
const CLAIMS_NAMESPACE_V3 = "claims.jwt.hasura.io"

///|
/// base64url (パディング無し) をデコードして UTF-8 文字列にする
fn b64url_decode(part : String) -> String raise AuthError {
  // トークンにパディングが付いていても許容する
  let stripped = part.trim_end(chars="=").to_owned()
  @base64.url_decode2str(stripped, no_padding=true) catch {
    _ => raise Unauthorized("invalid JWT: bad base64url encoding")
  }
}

///|
/// タイミング差を作らない文字列比較 (長さが違う場合のみ即 false)
fn constant_time_eq(a : String, b : String) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let xs = a.to_array()
  let ys = b.to_array()
  let mut diff = 0
  for i in 0..<xs.length() {
    diff = diff | (xs[i].to_int() ^ ys[i].to_int())
  }
  diff == 0
}

///|
/// HS256 署名付き JWT を検証してペイロード (JSON) を返す。
/// now_epoch_secs に None を渡すと exp / nbf の時刻検査をスキップする (テスト用途)
pub fn verify_jwt_hs256(
  token : String,
  secret : String,
  now_epoch_secs~ : Int64?,
) -> Json raise AuthError {
  let parts = token.split(".").map(s => s.to_owned()).collect()
  if parts.length() != 3 {
    raise Unauthorized("invalid JWT: expected 3 segments")
  }
  let header_json = @json.parse(b64url_decode(parts[0])) catch {
    _ => raise Unauthorized("invalid JWT: header is not valid JSON")
  }
  match header_json {
    Json::Object(h) =>
      match h.get("alg") {
        Some(Json::String("HS256")) => ()
        Some(Json::String(other)) =>
          raise Unauthorized("invalid JWT: unsupported alg \{other}")
        _ => raise Unauthorized("invalid JWT: missing alg")
      }
    _ => raise Unauthorized("invalid JWT: header is not an object")
  }
  // 署名検証: base64url(HMAC-SHA256(header.payload, secret))
  let signing_input = "\{parts[0]}.\{parts[1]}"
  let expected = @sha256.gen_hmac(
      @base64.str2bytes(signing_input),
      @base64.str2bytes(secret),
    )
    .trim_end(chars="=")
    .to_owned()
  let provided = parts[2].trim_end(chars="=").to_owned()
  if !constant_time_eq(expected, provided) {
    raise Unauthorized("invalid JWT: signature verification failed")
  }
  let payload = @json.parse(b64url_decode(parts[1])) catch {
    _ => raise Unauthorized("invalid JWT: payload is not valid JSON")
  }
  // exp / nbf 検査 (現在時刻が与えられた場合のみ)。
  // クレームが存在するのに数値でない場合は不正なトークンとして拒否する
  match (now_epoch_secs, payload) {
    (Some(now), Json::Object(p)) => {
      match p.get("exp") {
        Some(Json::Number(exp, ..)) =>
          if now >= exp.to_int64() {
            raise Unauthorized("invalid JWT: token has expired")
          }
        Some(_) => raise Unauthorized("invalid JWT: exp claim is not a number")
        None => ()
      }
      match p.get("nbf") {
        Some(Json::Number(nbf, ..)) =>
          if now < nbf.to_int64() {
            raise Unauthorized("invalid JWT: token is not yet valid (nbf)")
          }
        Some(_) => raise Unauthorized("invalid JWT: nbf claim is not a number")
        None => ()
      }
    }
    _ => ()
  }
  payload
}

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
