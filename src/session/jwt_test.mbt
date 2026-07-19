// JWT (HS256) 検証と resolve_session の JWT モードのテスト

///|
const TEST_SECRET = "3EK6FD+o0+c7tzBNVfjpMkNDi2yARAAKzQlk8O2IKoxQu4nF7EdAh8s3TwpHwrdWT6R"

///|
fn b64url_encode(s : String) -> String {
  let bytes = @base64.str2bytes(s)
  @base64.url_encode2str(FixedArray::from_iter(bytes.iter()), no_padding=true)
}

///|
fn make_token(payload : String, secret? : String = TEST_SECRET) -> String {
  let header = b64url_encode("{\"alg\":\"HS256\",\"typ\":\"JWT\"}")
  let body = b64url_encode(payload)
  let sig = @sha256.gen_hmac(
      @base64.str2bytes("\{header}.\{body}"),
      @base64.str2bytes(secret),
    )
    .trim_end(chars="=")
    .to_owned()
  "\{header}.\{body}.\{sig}"
}

///|
const CLAIMS_PAYLOAD = "{\"sub\":\"1234567890\",\"https://hasura.io/jwt/claims\":{\"x-hasura-default-role\":\"user\",\"x-hasura-allowed-roles\":[\"user\",\"editor\"],\"x-hasura-user-id\":\"42\"}}"

///|
fn jwt_auth() -> @metadata.AuthConfig? {
  Some({
    admin_secret: None,
    jwt_hs256_secret: Some(TEST_SECRET),
    jwt_hs256_secret_from_env: None,
  })
}

///|
test "JWT: 正しい署名のトークンで claims からセッションが得られる" {
  let token = make_token(CLAIMS_PAYLOAD)
  let session = resolve_session(jwt_auth(), {
    "Authorization": "Bearer \{token}",
  })
  assert_eq(session.role, "user")
  assert_eq(session.variables.get("x-hasura-user-id"), Some("42"))
}

///|
test "JWT: x-hasura-role ヘッダで allowed-roles 内のロールに切替できる" {
  let token = make_token(CLAIMS_PAYLOAD)
  let session = resolve_session(jwt_auth(), {
    "Authorization": "Bearer \{token}",
    "x-hasura-role": "editor",
  })
  assert_eq(session.role, "editor")
}

///|
test "JWT: allowed-roles 外のロール切替は拒否される" {
  let token = make_token(CLAIMS_PAYLOAD)
  try
    resolve_session(jwt_auth(), {
      "Authorization": "Bearer \{token}",
      "x-hasura-role": "admin",
    })
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected Unauthorized")
  }
}

///|
test "JWT: 署名が不正なトークンは拒否される" {
  let token = make_token(
    CLAIMS_PAYLOAD,
    secret="wrong-secret-wrong-secret-wrong-secret",
  )
  try
    resolve_session(jwt_auth(), { "Authorization": "Bearer \{token}" })
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected Unauthorized")
  }
}

///|
test "JWT: 改竄されたペイロードは拒否される" {
  let token = make_token(CLAIMS_PAYLOAD)
  let parts = token.split(".").map(s => s.to_owned()).collect()
  let tampered_body = b64url_encode(
    "{\"https://hasura.io/jwt/claims\":{\"x-hasura-default-role\":\"admin\",\"x-hasura-allowed-roles\":[\"admin\"]}}",
  )
  let tampered = "\{parts[0]}.\{tampered_body}.\{parts[2]}"
  try
    resolve_session(jwt_auth(), { "Authorization": "Bearer \{tampered}" })
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected Unauthorized")
  }
}

///|
test "JWT: alg=none は拒否される" {
  let header = b64url_encode("{\"alg\":\"none\",\"typ\":\"JWT\"}")
  let body = b64url_encode(CLAIMS_PAYLOAD)
  try
    resolve_session(jwt_auth(), { "Authorization": "Bearer \{header}.\{body}." })
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected Unauthorized")
  }
}

///|
test "JWT: exp が過去のトークンは now を与えると拒否される" {
  let payload = "{\"exp\":1000000000,\"https://hasura.io/jwt/claims\":{\"x-hasura-default-role\":\"user\",\"x-hasura-allowed-roles\":[\"user\"]}}"
  let token = make_token(payload)
  let headers : Map[String, String] = { "Authorization": "Bearer \{token}" }
  // now 指定なしなら exp は検査されない
  let ok = resolve_session(jwt_auth(), headers)
  assert_eq(ok.role, "user")
  // now が exp を過ぎていれば拒否
  try
    resolve_session(jwt_auth(), headers, now_epoch_secs=Some(2000000000L))
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected Unauthorized")
  }
  // now が exp より前なら通る
  let ok2 = resolve_session(
    jwt_auth(),
    headers,
    now_epoch_secs=Some(999999999L),
  )
  assert_eq(ok2.role, "user")
}

///|
test "JWT: V3 形式の claims 名前空間 (claims.jwt.hasura.io) も読める" {
  let payload = "{\"claims.jwt.hasura.io\":{\"x-hasura-default-role\":\"viewer\",\"x-hasura-allowed-roles\":[\"viewer\"],\"x-hasura-org-id\":123}}"
  let token = make_token(payload)
  let session = resolve_session(jwt_auth(), {
    "Authorization": "Bearer \{token}",
  })
  assert_eq(session.role, "viewer")
  assert_eq(session.variables.get("x-hasura-org-id"), Some("123"))
}

///|
test "JWT: claims 名前空間が無いトークンは拒否される" {
  let token = make_token("{\"sub\":\"nobody\"}")
  try
    resolve_session(jwt_auth(), { "Authorization": "Bearer \{token}" })
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected Unauthorized")
  }
}

///|
test "JWT: Authorization ヘッダが無ければ拒否される" {
  try resolve_session(jwt_auth(), Map([])) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected Unauthorized")
  }
}

///|
test "併用: admin-secret ヘッダ提示時は開発モード、無ければ JWT" {
  let auth : @metadata.AuthConfig? = Some({
    admin_secret: Some("topsecret"),
    jwt_hs256_secret: Some(TEST_SECRET),
    jwt_hs256_secret_from_env: None,
  })
  // admin-secret 提示 → 開発モードで任意ロール
  let dev = resolve_session(auth, {
    "x-hasura-admin-secret": "topsecret",
    "x-hasura-role": "anything",
  })
  assert_eq(dev.role, "anything")
  // admin-secret なし → JWT モード
  let token = make_token(CLAIMS_PAYLOAD)
  let jwt = resolve_session(auth, { "Authorization": "Bearer \{token}" })
  assert_eq(jwt.role, "user")
  // どちらも無ければ拒否
  try resolve_session(auth, Map([])) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected Unauthorized")
  }
}

///|
test "外部生成トークン: jwt.io 相当の固定トークンを検証できる" {
  // header {"alg":"HS256","typ":"JWT"} / payload {"sub":"1234567890","name":"John Doe","iat":1516239022} / secret "your-256-bit-secret"
  let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
  let payload = verify_jwt_hs256(token, "your-256-bit-secret")
  match payload {
    Json::Object(p) => assert_eq(p.get("name"), Some(Json::string("John Doe")))
    _ => fail("payload is not an object")
  }
}
