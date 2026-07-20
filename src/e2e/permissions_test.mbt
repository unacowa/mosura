// M5 E2E テスト: ロール別の行フィルタ (ModelPermissions) とカラム制限 (TypePermissions)

///|
fn m5_metadata(sfx : String) -> @metadata.Metadata raise {
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
      #|kind: ModelPermissions
      #|version: v1
      #|definition:
      #|  modelName: articles
      #|  permissions:
      #|    - role: user
      #|      select:
      #|        filter:
      #|          fieldComparison:
      #|            field: author_id
      #|            operator: _eq
      #|            value:
      #|              sessionVariable: x-hasura-user-id
      #|---
      #|kind: TypePermissions
      #|version: v1
      #|definition:
      #|  typeName: article
      #|  permissions:
      #|    - role: user
      #|      output:
      #|        allowedFields: [id, title]
    ).replace_all(old="__SFX__", new=sfx),
  )
}

///|
async fn run_graphql_as(
  sfx : String,
  session : @session.Session,
  query : String,
) -> String {
  let meta = m5_metadata(sfx)
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
      application_name="mosura-e2e-m5",
    )
    let (executor, connection) = @native.NativeExecutor::connect(config)
    group.spawn_bg(() => connection.run())
    seed(executor.client, sfx)
    let body : Map[String, Json] = { "query": Json::string(query) }
    let result = @engine.execute_request(
      ctx,
      session,
      executor,
      Json::object(body),
    )
    response = result.stringify()
    executor.client.close()
  })
  response
}

///|
fn user_session(user_id : String) -> @session.Session {
  let vars : Map[String, String] = { "x-hasura-user-id": user_id }
  { role: "user", variables: vars }
}

///|
async test "M5 E2E: user ロールは自分の行しか読めない" {
  let response = run_graphql_as(
    "p1",
    user_session("1"),
    "{ articles(order_by: [{id: Asc}]) { id title } }",
  )
  // author_id = 1 の記事のみ (id 1, 3)
  inspect(
    response,
    content=(
      #|{"data":{"articles":[{"id":1,"title":"Intro to MoonBit"},{"id":3,"title":"MoonBit and GraphQL"}]}}
    ),
  )
}

///|
async test "M5 E2E: user ロールは許可されていないカラムを読めない" {
  let response = run_graphql_as(
    "p2",
    user_session("1"),
    "{ articles { id author_id } }",
  )
  inspect(
    response,
    content=(
      #|{"errors":[{"message":"no such field on type article: author_id"}]}
    ),
  )
}

///|
async test "M5 E2E: 未知のロールにはモデル自体が見えない" {
  let response = run_graphql_as(
    "p3",
    { role: "anonymous", variables: Map([]) },
    "{ articles { id } }",
  )
  inspect(
    response,
    content=(
      #|{"errors":[{"message":"no such field on type query_root: articles"}]}
    ),
  )
}

///|
async test "M5 E2E: admin は全行・全カラムを読める" {
  let response = run_graphql_as(
    "p4",
    @session.Session::admin(),
    "{ articles(order_by: [{id: Asc}]) { id author_id } }",
  )
  inspect(
    response,
    content=(
      #|{"data":{"articles":[{"id":1,"author_id":1},{"id":2,"author_id":2},{"id":3,"author_id":1}]}}
    ),
  )
}
