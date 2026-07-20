// v3_compat の boolean expression 解決のユニットテスト
// (新形式 BooleanExpressionType / 旧 ObjectBooleanExpressionType / fail-closed)

///|
fn v3_objects(objects_json : String) -> Json raise {
  @json.parse(
    "{\"version\":\"v2\",\"subgraphs\":[{\"name\":\"default\",\"objects\":\{objects_json}}]}",
  )
}

///|
const V3_ARTICLE_TYPE_AND_CONNECTOR =
  #|{"kind":"DataConnectorLink","version":"v1","definition":{"name":"db","connection":{"urlFromEnv":"PG_MAIN_URL"}}},
  #|{"kind":"ObjectType","version":"v1","definition":{"name":"article","fields":[{"name":"id","type":"Int!"},{"name":"title","type":"String!"}]}}

///|
test "v3_compat: 新形式 BooleanExpressionType から filterableFields が解決される" {
  let j = v3_objects(
    (
      #|[
    ) +
    V3_ARTICLE_TYPE_AND_CONNECTOR +
    (
      #|,
      #|{"kind":"BooleanExpressionType","version":"v1","definition":{
      #|  "name":"article_bool_exp",
      #|  "operand":{"object":{"type":"article",
      #|    "comparableFields":[
      #|      {"fieldName":"id","booleanExpressionType":"Int_comparison_exp"},
      #|      {"fieldName":"title","booleanExpressionType":"String_comparison_exp"}],
      #|    "comparableRelationships":[]}},
      #|  "logicalOperators":{"enable":true},
      #|  "isNull":{"enable":true}}},
      #|{"kind":"Model","version":"v1","definition":{
      #|  "name":"articles","objectType":"article",
      #|  "source":{"dataConnectorName":"db","collection":"article"},
      #|  "filterExpressionType":"article_bool_exp"}}
      #|]
    ),
  )
  let r = load_v3_metadata(j)
  let model = r.metadata.models.get("articles").unwrap()
  assert_eq(model.filterable_fields, ["id", "title"])
}

///|
test "v3_compat: 旧 ObjectBooleanExpressionType も従来通り解決される" {
  let j = v3_objects(
    (
      #|[
    ) +
    V3_ARTICLE_TYPE_AND_CONNECTOR +
    (
      #|,
      #|{"kind":"ObjectBooleanExpressionType","version":"v1","definition":{
      #|  "name":"article_bool_exp","objectType":"article",
      #|  "comparableFields":[{"fieldName":"id","operators":{"enableAll":true}}]}},
      #|{"kind":"Model","version":"v1","definition":{
      #|  "name":"articles","objectType":"article",
      #|  "source":{"dataConnectorName":"db","collection":"article"},
      #|  "filterExpressionType":"article_bool_exp"}}
      #|]
    ),
  )
  let r = load_v3_metadata(j)
  let model = r.metadata.models.get("articles").unwrap()
  assert_eq(model.filterable_fields, ["id"])
}

///|
test "v3_compat: 未解決の filterExpressionType は fail-closed で拒否される" {
  let j = v3_objects(
    (
      #|[
    ) +
    V3_ARTICLE_TYPE_AND_CONNECTOR +
    (
      #|,
      #|{"kind":"Model","version":"v1","definition":{
      #|  "name":"articles","objectType":"article",
      #|  "source":{"dataConnectorName":"db","collection":"article"},
      #|  "filterExpressionType":"missing_bool_exp"}}
      #|]
    ),
  )
  try load_v3_metadata(j) |> ignore catch {
    MetadataParse(msg) => assert_true(msg.contains("missing_bool_exp"))
    _ => fail("expected MetadataParse")
  } noraise {
    _ => fail("expected MetadataParse (fail-closed), got a successful load")
  }
}

///|
test "v3_compat: object 型表記のフィールドを持つ ObjectType は読み飛ばす (ロードは成功)" {
  // article は object 表記の型 (未対応) を持つ → skip。
  // それを参照する Model articles も dangling で除外され、
  // 併存する健全な ObjectType/Model (tag) は読める
  let j = v3_objects(
    (
      #|[
      #|{"kind":"DataConnectorLink","version":"v1","definition":{"name":"db","connection":{"urlFromEnv":"PG_MAIN_URL"}}},
      #|{"kind":"ObjectType","version":"v1","definition":{
      #|  "name":"article",
      #|  "fields":[{"name":"id","type":"Int!"},{"name":"meta","type":{"nullable":false,"type":"named"}}]}},
      #|{"kind":"Model","version":"v1","definition":{
      #|  "name":"articles","objectType":"article",
      #|  "source":{"dataConnectorName":"db","collection":"article"}}},
      #|{"kind":"ObjectType","version":"v1","definition":{
      #|  "name":"tag","fields":[{"name":"id","type":"Int!"}]}},
      #|{"kind":"Model","version":"v1","definition":{
      #|  "name":"tags","objectType":"tag",
      #|  "source":{"dataConnectorName":"db","collection":"tag"}}}
      #|]
    ),
  )
  let r = load_v3_metadata(j)
  // 健全な tag/tags は読めている
  assert_true(r.metadata.models.get("tags") is Some(_))
  assert_true(r.metadata.object_types.get("tag") is Some(_))
  // 未対応型を持つ article/articles は除外されている
  assert_true(r.metadata.models.get("articles") is None)
  assert_true(r.skipped_kinds.contains("ObjectType(unsupported field type)"))
}
