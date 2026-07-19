// M4 E2E テスト: 実 PostgreSQL に対する GraphQL リクエスト → レスポンス検証。
// 接続先は環境変数 (無ければ localhost:5435 の test/test/test = 開発用コンテナ)

///|
fn pg_host() -> String {
  match @env.get_env_var("MOSURA_TEST_PG_HOST") {
    Some(h) => h
    None => "localhost"
  }
}

///|
fn pg_port() -> Int {
  match @env.get_env_var("MOSURA_TEST_PG_PORT") {
    Some(p) =>
      match (try? @string.parse_int(p)) {
        Ok(v) => v
        Err(_) => 5435
      }
    None => 5435
  }
}

///|
fn pg_user() -> String {
  match @env.get_env_var("MOSURA_TEST_PG_USER") {
    Some(u) => u
    None => "test"
  }
}

///|
fn pg_password() -> String {
  match @env.get_env_var("MOSURA_TEST_PG_PASSWORD") {
    Some(p) => p
    None => "test"
  }
}

///|
fn pg_database() -> String {
  match @env.get_env_var("MOSURA_TEST_PG_DB") {
    Some(d) => d
    None => "test"
  }
}

///|
fn e2e_metadata(sfx : String) -> @metadata.Metadata raise {
  @metadata.load_yaml(
    (
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
      #|    collection: mosura_e2e_articles__SFX__
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
      #|    collection: mosura_e2e_authors__SFX__
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
    ).replace_all(old="__SFX__", new=sfx),
  )
}

///|
async fn seed(client : @client.Client, sfx : String) -> Unit {
  client.batch_execute(
    (
      #|DROP TABLE IF EXISTS mosura_e2e_articles__SFX__;
      #|DROP TABLE IF EXISTS mosura_e2e_authors__SFX__;
      #|CREATE TABLE mosura_e2e_authors__SFX__ (id int primary key, name text not null);
      #|CREATE TABLE mosura_e2e_articles__SFX__ (id int primary key, title text not null, author_id int not null);
      #|INSERT INTO mosura_e2e_authors__SFX__ VALUES (1, 'Alice'), (2, 'Bob');
      #|INSERT INTO mosura_e2e_articles__SFX__ VALUES
      #|  (1, 'Intro to MoonBit', 1),
      #|  (2, 'Hasura internals', 2),
      #|  (3, 'MoonBit and GraphQL', 1);
    ).replace_all(old="__SFX__", new=sfx),
  )
}

///|
async fn run_graphql(sfx : String, query : String, variables : Json?) -> String {
  let meta = e2e_metadata(sfx)
  let ctx = @engine.EngineContext::new(meta)
  let mut response = ""
  @async.with_task_group(group => {
    let config = @client.Config::new(
      pg_host(),
      port=pg_port(),
      user=pg_user(),
      database=pg_database(),
      password=pg_password(),
      ssl_mode=@client.SslMode::Disable,
      application_name="mosura-e2e",
    )
    let (executor, connection) = @native.NativeExecutor::connect(config)
    group.spawn_bg(() => connection.run())
    seed(executor.client, sfx)
    let body : Map[String, Json] = { "query": Json::string(query) }
    match variables {
      Some(v) => body["variables"] = v
      None => ()
    }
    let result = @engine.execute_request(
      ctx,
      @schema.NamespaceCtx::AllowAll,
      executor,
      Json::object(body),
    )
    response = result.stringify()
    executor.client.close()
  })
  response
}

///|
async test "M4 E2E: filter + order + object relationship" {
  let response = run_graphql(
    "t1",
    (
      #|{
      #|  articles(where: {author_id: {_eq: 1}}, order_by: [{id: asc}]) {
      #|    id
      #|    title
      #|    author { name }
      #|  }
      #|}
    ),
    None,
  )
  inspect(
    response,
    content=(
      #|{"data":{"articles":[{"id":1,"title":"Intro to MoonBit","author":{"name":"Alice"}},{"id":3,"title":"MoonBit and GraphQL","author":{"name":"Alice"}}]}}
    ),
  )
}

///|
async test "M4 E2E: by_pk + __typename + array relationship" {
  let response = run_graphql(
    "t2",
    (
      #|{
      #|  authors_by_pk(id: 1) {
      #|    __typename
      #|    name
      #|    articles(order_by: [{id: desc}], limit: 1) { title }
      #|  }
      #|}
    ),
    None,
  )
  inspect(
    response,
    content=(
      #|{"data":{"authors_by_pk":{"__typename":"author","name":"Alice","articles":[{"title":"MoonBit and GraphQL"}]}}}
    ),
  )
}

///|
async test "M4 E2E: 変数と _in / _like" {
  let vars : Map[String, Json] = {
    "ids": Json::array([Json::number(1), Json::number(2)]),
  }
  let response = run_graphql(
    "t3",
    (
      #|query($ids: [Int!]) {
      #|  articles(where: {_and: [{id: {_in: $ids}}, {title: {_like: "%Moon%"}}]}) {
      #|    id
      #|  }
      #|}
    ),
    Some(Json::object(vars)),
  )
  inspect(
    response,
    content=(
      #|{"data":{"articles":[{"id":1}]}}
    ),
  )
}

///|
async test "M4 E2E: バリデーションエラー (存在しないフィールド)" {
  let response = run_graphql("t4", "{ articles { nonexistent } }", None)
  inspect(
    response,
    content=(
      #|{"errors":[{"message":"no such field on type article: nonexistent"}]}
    ),
  )
}
