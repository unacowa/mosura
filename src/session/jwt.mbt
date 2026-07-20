// JWT 検証コア (provider 非依存)。
//
// Hasura / Mosura 固有の要素は一切含まず、JWT の構造検証・署名検証・
// exp / nbf の時刻検査のみを行う。Hasura claims の解釈は hasura_claims.mbt。
// この分離により、将来この層を単体の MoonBit JWT ライブラリとして
// 切り出せる (fetch や時刻は呼び出し側が注入する。ここは pure)。
//
// 対応アルゴリズム:
// - HS256 (共有シークレット)
// - RS256 (RSASSA-PKCS1-v1_5 + SHA-256。公開鍵 n / e を渡す。検証は公開入力の
//   公開鍵演算なので乱数・定数時間は不要)
//
// exp / nbf (epoch 秒) は now_epoch_secs が与えられた場合のみ検査する。
// このパッケージは pure (時刻を取得しない) ため now は必須引数で呼び出し側が渡す。

///|
/// JWT 検証鍵 (アルゴリズムと鍵素材)
pub(all) enum JwtKey {
  /// HS256 共有シークレット
  Hs256(String)
  /// RS256 公開鍵 (JWK の n / e、いずれも base64url パディング無し)
  Rs256(modulus~ : String, exponent~ : String)
}

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
/// base64url (パディング無し) をデコードしてバイト列にする
fn b64url_decode_bytes(part : String) -> Bytes raise AuthError {
  let stripped = part.trim_end(chars="=").to_owned()
  @base64.url_decode2bytes(stripped, no_padding=true) catch {
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
/// 署名付き JWT を検証してペイロード (JSON) を返す。
/// key のアルゴリズムとトークンヘッダの alg が一致しなければ拒否する。
/// now_epoch_secs に None を渡すと exp / nbf の時刻検査をスキップする (テスト用途)
pub fn verify_jwt(
  token : String,
  key : JwtKey,
  now_epoch_secs~ : Int64?,
) -> Json raise AuthError {
  let parts = token.split(".").map(s => s.to_owned()).collect()
  if parts.length() != 3 {
    raise Unauthorized("invalid JWT: expected 3 segments")
  }
  let header_json = @json.parse(b64url_decode(parts[0])) catch {
    _ => raise Unauthorized("invalid JWT: header is not valid JSON")
  }
  let alg = match header_json {
    Json::Object(h) =>
      match h.get("alg") {
        Some(Json::String(a)) => a
        _ => raise Unauthorized("invalid JWT: missing alg")
      }
    _ => raise Unauthorized("invalid JWT: header is not an object")
  }
  let signing_input = "\{parts[0]}.\{parts[1]}"
  // アルゴリズムは鍵の種類で決まる (alg ヘッダの詐称による格下げを防ぐ)
  match key {
    Hs256(secret) => {
      if alg != "HS256" {
        raise Unauthorized("invalid JWT: expected HS256 but alg is \{alg}")
      }
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
    }
    Rs256(modulus~, exponent~) => {
      if alg != "RS256" {
        raise Unauthorized("invalid JWT: expected RS256 but alg is \{alg}")
      }
      let signature = b64url_decode_bytes(parts[2])
      let n = b64url_decode_bytes(modulus)
      let e = b64url_decode_bytes(exponent)
      if !rsa_pkcs1_v15_sha256_verify(signing_input, signature, n, e) {
        raise Unauthorized("invalid JWT: signature verification failed")
      }
    }
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
/// HS256 署名付き JWT を検証してペイロードを返す (後方互換の薄いラッパ)
pub fn verify_jwt_hs256(
  token : String,
  secret : String,
  now_epoch_secs~ : Int64?,
) -> Json raise AuthError {
  verify_jwt(token, Hs256(secret), now_epoch_secs~)
}

///|
/// SHA-256(input) の生ダイジェスト (32 バイト) を返す。
/// gmlewis/sha256 は check_sum (hex 文字列) を公開しているのでそれを復号する
fn sha256_digest(input : String) -> Bytes {
  let d = @sha256.Digest::new()
  for b in @base64.str2bytes(input) {
    d.write(b)
  }
  hex_to_bytes(d.check_sum())
}

///|
/// hex 文字列 (小文字) をバイト列にする
fn hex_to_bytes(hex : String) -> Bytes {
  let chars = hex.to_array()
  let out : Array[Byte] = []
  fn nibble(c : Char) -> Int {
    let v = c.to_int()
    if v >= '0'.to_int() && v <= '9'.to_int() {
      v - '0'.to_int()
    } else if v >= 'a'.to_int() && v <= 'f'.to_int() {
      v - 'a'.to_int() + 10
    } else {
      v - 'A'.to_int() + 10
    }
  }

  for i in 0..<(chars.length() / 2) {
    let hi = nibble(chars[i * 2])
    let lo = nibble(chars[i * 2 + 1])
    out.push(((hi << 4) | lo).to_byte())
  }
  Bytes::from_array(out[:])
}

///|
/// SHA-256 の DigestInfo プレフィックス (RFC 8017 EMSA-PKCS1-v1_5)
let sha256_digest_info : Array[Int] = [
  0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02,
  0x01, 0x05, 0x00, 0x04, 0x20,
]

///|
/// RSASSA-PKCS1-v1_5 + SHA-256 の署名検証。
/// s^e mod n を計算して EMSA-PKCS1-v1_5 エンコード (0x00 01 FF..FF 00 T) と
/// 突き合わせる。T = DigestInfo(SHA-256) || SHA-256(signing_input)。
/// 公開入力の公開鍵演算なので定数時間比較は不要
fn rsa_pkcs1_v15_sha256_verify(
  signing_input : String,
  signature : Bytes,
  n : Bytes,
  e : Bytes,
) -> Bool {
  let k = n.length()
  // 署名長は modulus 長と一致していなければならない
  if signature.length() != k {
    return false
  }
  let n_int = @bigint.BigInt::from_octets(n[:])
  let e_int = @bigint.BigInt::from_octets(e[:])
  let s_int = @bigint.BigInt::from_octets(signature[:])
  // s は [0, n) の範囲でなければならない
  if s_int >= n_int {
    return false
  }
  let m_int = s_int.pow(e_int, modulus=n_int)
  let em = m_int.to_octets(length=k)
  // 期待する EM を構築: 0x00 || 0x01 || PS(0xFF..) || 0x00 || T
  let digest = sha256_digest(signing_input)
  let t_len = sha256_digest_info.length() + digest.length()
  // 最小の PS は 8 バイト。k < t_len + 11 なら不正
  if k < t_len + 11 {
    return false
  }
  let expected = FixedArray::make(k, b'\x00')
  expected[0] = b'\x00'
  expected[1] = b'\x01'
  let ps_end = k - t_len - 1
  for i in 2..<ps_end {
    expected[i] = b'\xff'
  }
  expected[ps_end] = b'\x00'
  let mut idx = ps_end + 1
  for b in sha256_digest_info {
    expected[idx] = b.to_byte()
    idx += 1
  }
  for i in 0..<digest.length() {
    expected[idx] = digest[i]
    idx += 1
  }
  // 復元した EM と期待値をバイト比較
  for i in 0..<k {
    if em[i] != expected[i] {
      return false
    }
  }
  true
}
