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
    jwt_rs256_modulus: None,
    jwt_rs256_exponent: None,
  })
}

///|
test "JWT: 正しい署名のトークンで claims からセッションが得られる" {
  let token = make_token(CLAIMS_PAYLOAD)
  let session = resolve_session(
    jwt_auth(),
    { "Authorization": "Bearer \{token}" },
    now_epoch_secs=None,
  )
  assert_eq(session.role, "user")
  assert_eq(session.variables.get("x-hasura-user-id"), Some("42"))
}

///|
test "JWT: x-hasura-role ヘッダで allowed-roles 内のロールに切替できる" {
  let token = make_token(CLAIMS_PAYLOAD)
  let session = resolve_session(
    jwt_auth(),
    { "Authorization": "Bearer \{token}", "x-hasura-role": "editor" },
    now_epoch_secs=None,
  )
  assert_eq(session.role, "editor")
}

///|
test "JWT: allowed-roles 外のロール切替は拒否される" {
  let token = make_token(CLAIMS_PAYLOAD)
  try
    resolve_session(
      jwt_auth(),
      { "Authorization": "Bearer \{token}", "x-hasura-role": "admin" },
      now_epoch_secs=None,
    )
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
    resolve_session(
      jwt_auth(),
      { "Authorization": "Bearer \{token}" },
      now_epoch_secs=None,
    )
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
    resolve_session(
      jwt_auth(),
      { "Authorization": "Bearer \{tampered}" },
      now_epoch_secs=None,
    )
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
    resolve_session(
      jwt_auth(),
      { "Authorization": "Bearer \{header}.\{body}." },
      now_epoch_secs=None,
    )
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
  let ok = resolve_session(jwt_auth(), headers, now_epoch_secs=None)
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
  let session = resolve_session(
    jwt_auth(),
    { "Authorization": "Bearer \{token}" },
    now_epoch_secs=None,
  )
  assert_eq(session.role, "viewer")
  assert_eq(session.variables.get("x-hasura-org-id"), Some("123"))
}

///|
test "JWT: claims 名前空間が無いトークンは拒否される" {
  let token = make_token("{\"sub\":\"nobody\"}")
  try
    resolve_session(
      jwt_auth(),
      { "Authorization": "Bearer \{token}" },
      now_epoch_secs=None,
    )
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected Unauthorized")
  }
}

///|
test "JWT: Authorization ヘッダが無ければ拒否される" {
  try
    resolve_session(jwt_auth(), Map([]), now_epoch_secs=None) |> ignore
  catch {
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
    jwt_rs256_modulus: None,
    jwt_rs256_exponent: None,
  })
  // admin-secret 提示 → 開発モードで任意ロール
  let dev = resolve_session(
    auth,
    { "x-hasura-admin-secret": "topsecret", "x-hasura-role": "anything" },
    now_epoch_secs=None,
  )
  assert_eq(dev.role, "anything")
  // admin-secret なし → JWT モード
  let token = make_token(CLAIMS_PAYLOAD)
  let jwt = resolve_session(
    auth,
    { "Authorization": "Bearer \{token}" },
    now_epoch_secs=None,
  )
  assert_eq(jwt.role, "user")
  // どちらも無ければ拒否
  try resolve_session(auth, Map([]), now_epoch_secs=None) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected Unauthorized")
  }
}

///|
test "外部生成トークン: jwt.io 相当の固定トークンを検証できる" {
  // header {"alg":"HS256","typ":"JWT"} / payload {"sub":"1234567890","name":"John Doe","iat":1516239022} / secret "your-256-bit-secret"
  let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
  let payload = verify_jwt_hs256(
    token,
    "your-256-bit-secret",
    now_epoch_secs=None,
  )
  match payload {
    Json::Object(p) => assert_eq(p.get("name"), Some(Json::string("John Doe")))
    _ => fail("payload is not an object")
  }
}

///|
test "JWT: セグメント数が3でないトークンは拒否される" {
  for bad in ["onlyone", "two.parts", "a.b.c.d"] {
    try
      verify_jwt_hs256(bad, TEST_SECRET, now_epoch_secs=None) |> ignore
    catch {
      Unauthorized(_) => ()
    } noraise {
      _ => fail("expected Unauthorized for \{bad}")
    }
  }
}

///|
test "JWT: base64url として不正なセグメントは拒否される" {
  let body = b64url_encode(CLAIMS_PAYLOAD)
  try
    verify_jwt_hs256(
      "!!not-base64!!.\{body}.sig",
      TEST_SECRET,
      now_epoch_secs=None,
    )
    |> ignore
  catch {
    Unauthorized(_) => ()
  } noraise {
    _ => fail("expected Unauthorized")
  }
}

///|
test "JWT: ヘッダが JSON でない / オブジェクトでない場合は拒否される" {
  let body = b64url_encode(CLAIMS_PAYLOAD)
  for bad_header in [b64url_encode("not json at all"), b64url_encode("[1,2,3]")] {
    try
      verify_jwt_hs256(
        "\{bad_header}.\{body}.sig",
        TEST_SECRET,
        now_epoch_secs=None,
      )
      |> ignore
    catch {
      Unauthorized(_) => ()
    } noraise {
      _ => fail("expected Unauthorized")
    }
  }
}

///|
test "JWT: alg の無いヘッダは拒否される" {
  let header = b64url_encode("{\"typ\":\"JWT\"}")
  let body = b64url_encode(CLAIMS_PAYLOAD)
  try
    verify_jwt_hs256("\{header}.\{body}.sig", TEST_SECRET, now_epoch_secs=None)
    |> ignore
  catch {
    Unauthorized(_) => ()
  } noraise {
    _ => fail("expected Unauthorized")
  }
}

///|
test "JWT: Bearer 以外の Authorization スキームは拒否される" {
  let token = make_token(CLAIMS_PAYLOAD)
  try
    resolve_session(
      jwt_auth(),
      { "Authorization": "Basic \{token}" },
      now_epoch_secs=None,
    )
    |> ignore
  catch {
    Unauthorized(_) => ()
  } noraise {
    _ => fail("expected Unauthorized")
  }
}

///|
test "JWT: alg=HS256 で署名セグメントが空のトークンは拒否される (署名ストリッピング)" {
  let token = make_token(CLAIMS_PAYLOAD)
  let parts = token.split(".").map(s => s.to_owned()).collect()
  let stripped = "\{parts[0]}.\{parts[1]}."
  try
    resolve_session(
      jwt_auth(),
      { "Authorization": "Bearer \{stripped}" },
      now_epoch_secs=None,
    )
    |> ignore
  catch {
    Unauthorized(_) => ()
  } noraise {
    _ => fail("expected Unauthorized")
  }
}

///|
test "JWT: exp が数値でないトークンは now を与えると拒否される" {
  let payload = "{\"exp\":\"tomorrow\",\"https://hasura.io/jwt/claims\":{\"x-hasura-default-role\":\"user\",\"x-hasura-allowed-roles\":[\"user\"]}}"
  let token = make_token(payload)
  try
    verify_jwt_hs256(token, TEST_SECRET, now_epoch_secs=Some(1000000000L))
    |> ignore
  catch {
    Unauthorized(_) => ()
  } noraise {
    _ => fail("expected Unauthorized")
  }
}

///|
test "JWT: nbf が未来のトークンは拒否され、nbf 以降なら通る" {
  let payload = "{\"nbf\":1500000000,\"https://hasura.io/jwt/claims\":{\"x-hasura-default-role\":\"user\",\"x-hasura-allowed-roles\":[\"user\"]}}"
  let token = make_token(payload)
  let headers : Map[String, String] = { "Authorization": "Bearer \{token}" }
  // now < nbf → 拒否
  try
    resolve_session(jwt_auth(), headers, now_epoch_secs=Some(1000000000L))
    |> ignore
  catch {
    Unauthorized(_) => ()
  } noraise {
    _ => fail("expected Unauthorized")
  }
  // now >= nbf → 通る
  let ok = resolve_session(
    jwt_auth(),
    headers,
    now_epoch_secs=Some(1500000000L),
  )
  assert_eq(ok.role, "user")
}

///|
test "JWT: 空の x-hasura-allowed-roles ではロール切替できない (default-role は使える)" {
  let payload = "{\"https://hasura.io/jwt/claims\":{\"x-hasura-default-role\":\"user\",\"x-hasura-allowed-roles\":[]}}"
  let token = make_token(payload)
  // ロール切替の要求は拒否
  try
    resolve_session(
      jwt_auth(),
      { "Authorization": "Bearer \{token}", "x-hasura-role": "user" },
      now_epoch_secs=None,
    )
    |> ignore
  catch {
    Unauthorized(_) => ()
  } noraise {
    _ => fail("expected Unauthorized")
  }
  // ヘッダ無しなら default-role で通る
  let ok = resolve_session(
    jwt_auth(),
    { "Authorization": "Bearer \{token}" },
    now_epoch_secs=None,
  )
  assert_eq(ok.role, "user")
}

///|
test "fail-closed: AuthConfig に利用可能な認証方式が無ければ admin にせず拒否する" {
  // 綴り間違い等で全フィールドが None になったケース
  let empty_auth : @metadata.AuthConfig? = Some({
    admin_secret: None,
    jwt_hs256_secret: None,
    jwt_hs256_secret_from_env: None,
    jwt_rs256_modulus: None,
    jwt_rs256_exponent: None,
  })
  try
    resolve_session(empty_auth, Map([]), now_epoch_secs=None) |> ignore
  catch {
    Unauthorized(_) => ()
  } noraise {
    _ => fail("expected Unauthorized (fail-closed)")
  }
  // jwtHs256SecretFromEnv がランタイム層で未解決のまま渡されたケース
  let unresolved_env : @metadata.AuthConfig? = Some({
    admin_secret: None,
    jwt_hs256_secret: None,
    jwt_hs256_secret_from_env: Some("MOSURA_JWT_SECRET"),
    jwt_rs256_modulus: None,
    jwt_rs256_exponent: None,
  })
  try
    resolve_session(
      unresolved_env,
      { "x-hasura-admin-secret": "anything" },
      now_epoch_secs=None,
    )
    |> ignore
  catch {
    Unauthorized(_) => ()
  } noraise {
    _ => fail("expected Unauthorized (fail-closed)")
  }
}

///|
// openssl 生成の 2048bit RSA 鍵で署名した RS256 トークンと JWK n/e (scratchpad で生成)
const RS256_TOKEN = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyLCJodHRwczovL2hhc3VyYS5pby9qd3QvY2xhaW1zIjp7IngtaGFzdXJhLWRlZmF1bHQtcm9sZSI6InVzZXIiLCJ4LWhhc3VyYS1hbGxvd2VkLXJvbGVzIjpbInVzZXIiLCJlZGl0b3IiXSwieC1oYXN1cmEtdXNlci1pZCI6IjQyIn19.GIPirJKcrifn0ZPQ1SMECrMaD_4QZd_iLOt-61qHp5dZKTlkFcyQXcKe-Lxh5mWH8d7k3YsKEz0g4-XctTkqzikRM9QQmgVp_s3bOmYFyb1Tgw4cCjfFiuUAqkiru2qYNU7wDLbZj4b2jCU9b6eqiteXOEoGvKXFTjTxF05oTwKDeMnPs4qIWYxlFBt9LHTNZzkDDH7UwBiyHIAs-jEU4DaHYeVTKby8wMqpbmW39wLQaCAop_xBHbk7kNyRPHOrOSZifo9GtyO5W_I_wCOEnvYPpwt08rdllHkQ8C7ouzkdKp8SCDcA9-ya5fv-NieoPaX5O6sYzvKNOZo3aSiU2w"

///|
const RS256_N = "3VOa-tgSGT1I9GXxd1z0fSVPvMr706vJe9grOdE6txvzRwFOzvkAliqLwl5wsQkqgVP00tsIMnuSInZqQSe_eiXeVWwoVMAWDGgp7_0G7QT1XQZ8Sdmy0NYkt5CrE_F_i4DvrSO4KY9_JV6qOkipSyrD9ARxKZwMtxPFqYbAS8fhO5UW9X5y5ZvcZvKMX5DdYIY7c_VrZVIyIIlHcFe-sAxQ6e0JfIAF5EeUtBF7E6OCyQRitnirbFMOJoS2kezffXhLgmPqdQezq2ov3k_kcyBFWByCTWeCdZcUCrNlej_GC2u3wA3om7npPZiCk-J_KpA6ycLFcxfVMEhGmogtiw"

///|
const RS256_E = "AQAB"

///|
fn rs256_auth() -> @metadata.AuthConfig? {
  Some({
    admin_secret: None,
    jwt_hs256_secret: None,
    jwt_hs256_secret_from_env: None,
    jwt_rs256_modulus: Some(RS256_N),
    jwt_rs256_exponent: Some(RS256_E),
  })
}

///|
test "JWT RS256: 正しい署名のトークンで claims からセッションが得られる" {
  let session = resolve_session(
    rs256_auth(),
    { "Authorization": "Bearer \{RS256_TOKEN}" },
    now_epoch_secs=None,
  )
  assert_eq(session.role, "user")
  assert_eq(session.variables.get("x-hasura-user-id"), Some("42"))
}

///|
test "JWT RS256: verify_jwt を直接呼んでペイロードを得る" {
  let payload = verify_jwt(
    RS256_TOKEN,
    Rs256(modulus=RS256_N, exponent=RS256_E),
    now_epoch_secs=None,
  )
  match payload {
    Json::Object(p) => assert_eq(p.get("name"), Some(Json::string("John Doe")))
    _ => fail("payload is not an object")
  }
}

///|
test "JWT RS256: 改竄されたペイロード (署名不一致) は拒否される" {
  // name を書き換えたが署名は元のまま
  let bad = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkphbmUgRG9lIiwiaWF0IjoxNTE2MjM5MDIyLCJodHRwczovL2hhc3VyYS5pby9qd3QvY2xhaW1zIjp7IngtaGFzdXJhLWRlZmF1bHQtcm9sZSI6InVzZXIiLCJ4LWhhc3VyYS1hbGxvd2VkLXJvbGVzIjpbInVzZXIiLCJlZGl0b3IiXSwieC1oYXN1cmEtdXNlci1pZCI6IjQyIn19.GIPirJKcrifn0ZPQ1SMECrMaD_4QZd_iLOt-61qHp5dZKTlkFcyQXcKe-Lxh5mWH8d7k3YsKEz0g4-XctTkqzikRM9QQmgVp_s3bOmYFyb1Tgw4cCjfFiuUAqkiru2qYNU7wDLbZj4b2jCU9b6eqiteXOEoGvKXFTjTxF05oTwKDeMnPs4qIWYxlFBt9LHTNZzkDDH7UwBiyHIAs-jEU4DaHYeVTKby8wMqpbmW39wLQaCAop_xBHbk7kNyRPHOrOSZifo9GtyO5W_I_wCOEnvYPpwt08rdllHkQ8C7ouzkdKp8SCDcA9-ya5fv-NieoPaX5O6sYzvKNOZo3aSiU2w"
  try
    verify_jwt(
      bad,
      Rs256(modulus=RS256_N, exponent=RS256_E),
      now_epoch_secs=None,
    )
    |> ignore
  catch {
    Unauthorized(_) => ()
  } noraise {
    _ => fail("expected Unauthorized (tampered payload)")
  }
}

///|
test "JWT RS256: HS256 鍵で RS256 トークンを検証しようとすると alg 不一致で拒否" {
  try
    verify_jwt(RS256_TOKEN, Hs256("whatever"), now_epoch_secs=None) |> ignore
  catch {
    Unauthorized(_) => ()
  } noraise {
    _ => fail("expected Unauthorized (alg mismatch)")
  }
}

///|
test "JWT RS256: RS256 鍵で HS256 トークンを検証しようとすると alg 不一致で拒否" {
  let hs_token = make_token(CLAIMS_PAYLOAD)
  try
    verify_jwt(
      hs_token,
      Rs256(modulus=RS256_N, exponent=RS256_E),
      now_epoch_secs=None,
    )
    |> ignore
  catch {
    Unauthorized(_) => ()
  } noraise {
    _ => fail("expected Unauthorized (alg mismatch)")
  }
}

///|
test "JWT RS256: YAML の AuthConfig(jwtRs256) を通しても検証できる (ローダ配線)" {
  let yaml = "kind: AuthConfig\nversion: v1\ndefinition:\n  jwtRs256:\n    modulus: \"" +
    RS256_N +
    "\"\n    exponent: \"AQAB\"\n"
  let meta = @metadata.load_yaml(yaml)
  let session = resolve_session(
    meta.auth,
    { "Authorization": "Bearer " + RS256_TOKEN },
    now_epoch_secs=None,
  )
  assert_eq(session.role, "user")
  assert_eq(session.variables.get("x-hasura-user-id"), Some("42"))
}
