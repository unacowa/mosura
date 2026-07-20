// M6 E2E テスト: ロール別ミューテーション権限
// (insert のカラムプリセット、update/delete の行フィルタ、許可カラム制限)

///|
fn m6p_metadata(sfx : String) -> @metadata.Metadata raise {
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
      #|      insert:
      #|        columns: [id, title]
      #|        presets:
      #|          - field: author_id
      #|            value:
      #|              sessionVariable: x-hasura-user-id
      #|      update:
      #|        columns: [title]
      #|        filter:
      #|          fieldComparison:
      #|            field: author_id
      #|            operator: _eq
      #|            value:
      #|              sessionVariable: x-hasura-user-id
      #|      delete:
      #|        filter:
      #|          fieldComparison:
      #|            field: author_id
      #|            operator: _eq
      #|            value:
      #|              sessionVariable: x-hasura-user-id
    ).replace_all(old="__SFX__", new=sfx),
  )
}

///|
async fn run_m6p_as(
  sfx : String,
  session : @session.Session,
  query : String,
) -> String {
  let meta = m6p_metadata(sfx)
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
      application_name="mosura-e2e-m6p",
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
async test "M6 権限 E2E: insert のプリセットで author_id がセッション変数に固定される" {
  let response = run_m6p_as(
    "mp1",
    user_session("2"),
    (
      #|mutation {
      #|  insert_articles(objects: [{id: 50, title: "mine"}]) {
      #|    affected_rows
      #|    returning { id title author_id }
      #|  }
      #|}
    ),
  )
  inspect(
    response,
    content=(
      #|{"data":{"insert_articles":{"affected_rows":1,"returning":[{"id":50,"title":"mine","author_id":2}]}}}
    ),
  )
}

///|
async test "M6 権限 E2E: プリセット対象カラムはユーザ入力不可" {
  let response = run_m6p_as(
    "mp2",
    user_session("2"),
    (
      #|mutation {
      #|  insert_articles(objects: [{id: 51, title: "spoof", author_id: 1}]) {
      #|    affected_rows
      #|  }
      #|}
    ),
  )
  // author_id はスキーマ上ユーザロールから見えないため validation エラーになる
  inspect(
    response,
    content=(
      #|{"errors":[{"message":"the field author_id on type article_insert_input is not found"}]}
    ),
  )
}

///|
async test "M6 権限 E2E: update は行フィルタで自分の行のみ" {
  // author_id=1 のセッションで自分の行 (id=1) は更新できる
  let own = run_m6p_as(
    "mp3",
    user_session("1"),
    (
      #|mutation {
      #|  update_articles_by_pk(id: 1, _set: {title: "mine now"}) { id title }
      #|}
    ),
  )
  inspect(
    own,
    content=(
      #|{"data":{"update_articles_by_pk":{"id":1,"title":"mine now"}}}
    ),
  )
  // 他人の行 (id=2 は author_id=2) は行フィルタで対象外 → null
  let other = run_m6p_as(
    "mp4",
    user_session("1"),
    (
      #|mutation {
      #|  update_articles_by_pk(id: 2, _set: {title: "hijack"}) { id title }
      #|}
    ),
  )
  inspect(
    other,
    content=(
      #|{"data":{"update_articles_by_pk":null}}
    ),
  )
}

///|
async test "M6 権限 E2E: delete は行フィルタで自分の行のみ" {
  // 他人の行は削除できない → null
  let other = run_m6p_as(
    "mp5",
    user_session("1"),
    (
      #|mutation {
      #|  delete_articles_by_pk(id: 2) { id }
      #|}
    ),
  )
  inspect(
    other,
    content=(
      #|{"data":{"delete_articles_by_pk":null}}
    ),
  )
  // 自分の行は削除できる
  let own = run_m6p_as(
    "mp5",
    user_session("1"),
    (
      #|mutation {
      #|  delete_articles_by_pk(id: 3) { id }
      #|}
    ),
  )
  inspect(
    own,
    content=(
      #|{"data":{"delete_articles_by_pk":{"id":3}}}
    ),
  )
}

///|
async test "M6 権限 E2E: update で許可カラム外の _set は不可" {
  let response = run_m6p_as(
    "mp6",
    user_session("1"),
    (
      #|mutation {
      #|  update_articles_by_pk(id: 1, _set: {author_id: 2}) { id }
      #|}
    ),
  )
  // update.columns = [title] のため author_id は _set 入力型に存在しない
  inspect(
    response,
    content=(
      #|{"errors":[{"message":"the field author_id on type article_set_input is not found"}]}
    ),
  )
}
