// M2 統合テスト: YAML メタデータ → スキーマ生成 → 正規化 → introspection 応答

///|
fn sample_metadata() -> @metadata.Metadata raise {
  let yaml =
    #|kind: DataConnectorLink
    #|version: v1
    #|definition:
    #|  name: pg_main
    #|  connection:
    #|    urlFromEnv: PG_MAIN_URL
    #|---
    #|kind: ObjectType
    #|version: v1
    #|definition:
    #|  name: article
    #|  fields:
    #|    - name: id
    #|      type: Int!
    #|    - name: title
    #|      type: String!
    #|    - name: author_id
    #|      type: Int!
    #|---
    #|kind: ObjectType
    #|version: v1
    #|definition:
    #|  name: author
    #|  fields:
    #|    - name: id
    #|      type: Int!
    #|    - name: name
    #|      type: String!
    #|---
    #|kind: Model
    #|version: v1
    #|definition:
    #|  name: articles
    #|  objectType: article
    #|  source:
    #|    dataConnectorName: pg_main
    #|    collection: articles
    #|  filterableFields: [id, title, author_id]
    #|  orderableFields: [id, title]
    #|  primaryKey: [id]
    #|---
    #|kind: Model
    #|version: v1
    #|definition:
    #|  name: authors
    #|  objectType: author
    #|  source:
    #|    dataConnectorName: pg_main
    #|    collection: authors
    #|  filterableFields: [id, name]
    #|  orderableFields: [id, name]
    #|  primaryKey: [id]
    #|---
    #|kind: Relationship
    #|version: v1
    #|definition:
    #|  name: author
    #|  sourceType: article
    #|  targetModel: authors
    #|  relationshipType: Object
    #|  mapping:
    #|    - sourceField: author_id
    #|      targetField: id
    #|---
    #|kind: Relationship
    #|version: v1
    #|definition:
    #|  name: articles
    #|  sourceType: author
    #|  targetModel: articles
    #|  relationshipType: Array
    #|  mapping:
    #|    - sourceField: id
    #|      targetField: author_id
  @metadata.load_yaml(yaml)
}

///|
fn run_query(query : String) -> @schema.NOperation raise {
  let meta = sample_metadata()
  let schema = build_schema(meta)
  let parser = @graphql.Parser::new(@utf8.encode(query))
  let doc = parser.parse_executable_document()
  @schema.normalize_request(AllowAll, schema, {
    query: doc,
    operation_name: None,
    variables: Map([]),
  })
}

///|
test "M2: メタデータからスキーマ生成 + クエリ正規化" {
  let op = run_query(
    (
      #|{
      #|  articles(where: {id: {_eq: 1}}, order_by: [{title: asc}], limit: 10) {
      #|    id
      #|    title
      #|    author { name }
      #|  }
      #|}
    ),
  )
  // ルートフィールドの検証
  assert_eq(op.selection_set.fields.length(), 1)
  let articles = op.selection_set.fields.values().collect()[0]
  let fc = articles.field_call()
  assert_eq(fc.name.as_str(), "articles")
  match fc.info.generic {
    ModelSelect(m) => assert_eq(m, "articles")
    _ => fail("expected ModelSelect annotation")
  }
  // 引数 where/order_by/limit が正規化されている
  assert_eq(fc.arguments.length(), 3)
  let where_arg = fc.arguments
    .get(@graphql.Name::new_unchecked("where"))
    .unwrap()
  inspect(
    where_arg.value.as_json().stringify(),
    content=(
      #|{"id":{"_eq":1}}
    ),
  )
  // ネストしたリレーションフィールド
  let author = articles.selection_set.fields
    .values()
    .collect()
    .filter(f => f.nalias.0.as_str() == "author")[0]
  match author.field_call().info.generic {
    RelationshipField(r) => assert_eq(r, "author")
    _ => fail("expected RelationshipField annotation")
  }
}

///|
test "M2: introspection (__schema queryType / types)" {
  let meta = sample_metadata()
  let schema = build_schema(meta)
  let parser = @graphql.Parser::new(
    @utf8.encode(
      (
        #|{
        #|  __schema {
        #|    queryType { name }
        #|    types { name kind }
        #|  }
        #|}
      ),
    ),
  )
  let doc = parser.parse_executable_document()
  let op = @schema.normalize_request(AllowAll, schema, {
    query: doc,
    operation_name: None,
    variables: Map([]),
  })
  let schema_field = op.selection_set.fields.values().collect()[0]
  let response = @schema.schema_type(
    schema,
    AllowAll,
    schema_field.selection_set,
  )
  // queryType 名
  let obj = match response {
    Json::Object(m) => m
    _ => fail("expected object")
  }
  inspect(
    obj.get("queryType").unwrap().stringify(),
    content=(
      #|{"name":"query_root"}
    ),
  )
  // 型一覧に生成した型が含まれる
  let type_names = match obj.get("types").unwrap() {
    Json::Array(items) =>
      items.map(i => {
        match i {
          Json::Object(m) =>
            match m.get("name").unwrap() {
              Json::String(s) => s
              _ => ""
            }
          _ => ""
        }
      })
    _ => fail("expected array")
  }
  for
    expected in [
      "Boolean", "Int", "Int_comparison_exp", "String", "String_comparison_exp",
      "__Schema", "__Type", "article", "article_bool_exp", "article_order_by", "author",
      "author_bool_exp", "author_order_by", "order_by", "query_root",
    ] {
    assert_true(type_names.contains(expected))
  }
}

///|
test "M2: __typename と変数つきクエリ" {
  let meta = sample_metadata()
  let schema = build_schema(meta)
  let parser = @graphql.Parser::new(
    @utf8.encode(
      (
        #|query($lim: Int) {
        #|  articles(limit: $lim) { __typename id }
        #|}
      ),
    ),
  )
  let doc = parser.parse_executable_document()
  let vars : Map[String, Json] = { "lim": Json::number(5) }
  let op = @schema.normalize_request(AllowAll, schema, {
    query: doc,
    operation_name: None,
    variables: vars,
  })
  let articles = op.selection_set.fields.values().collect()[0]
  let limit_arg = articles.field_call().arguments
    .get(@graphql.Name::new_unchecked("limit"))
    .unwrap()
  inspect(limit_arg.value.as_json().stringify(), content="5")
}
