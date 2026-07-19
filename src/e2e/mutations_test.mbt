// M6 E2E テスト: V2 風 CRUD (insert / update_by_pk / delete_by_pk)

///|
async test "M6 E2E: insert → update_by_pk → delete_by_pk" {
  let meta = e2e_metadata("m6")
  let ctx = @engine.EngineContext::new(meta)
  @async.with_task_group(group => {
    let config = @client.Config::new(
      pg_host(),
      port=pg_port(),
      user=pg_user(),
      database=pg_database(),
      password=pg_password(),
      ssl_mode=@client.SslMode::Disable,
      application_name="mosura-e2e-m6",
    )
    let (executor, connection) = @native.NativeExecutor::connect(config)
    group.spawn_bg(() => connection.run())
    seed(executor.client, "m6")
    let run = async fn(query : String) -> String {
      let body : Map[String, Json] = { "query": Json::string(query) }
      let result = @engine.execute_request(
        ctx,
        @session.Session::admin(),
        executor,
        Json::object(body),
      )
      result.stringify()
    }

    // insert (複数行 + mutation_response)
    let insert_response = run(
      (
        #|mutation {
        #|  insert_articles(objects: [
        #|    {id: 10, title: "New A", author_id: 1},
        #|    {id: 11, title: "New B", author_id: 2}
        #|  ]) {
        #|    affected_rows
        #|    returning { id title }
        #|  }
        #|}
      ),
    )
    inspect(
      insert_response,
      content=(
        #|{"data":{"insert_articles":{"affected_rows":2,"returning":[{"id":10,"title":"New A"},{"id":11,"title":"New B"}]}}}
      ),
    )

    // update_by_pk
    let update_response = run(
      (
        #|mutation {
        #|  update_articles_by_pk(id: 10, _set: {title: "Updated A"}) {
        #|    id
        #|    title
        #|  }
        #|}
      ),
    )
    inspect(
      update_response,
      content=(
        #|{"data":{"update_articles_by_pk":{"id":10,"title":"Updated A"}}}
      ),
    )

    // delete_by_pk
    let delete_response = run(
      (
        #|mutation {
        #|  delete_articles_by_pk(id: 11) { id }
        #|}
      ),
    )
    inspect(
      delete_response,
      content=(
        #|{"data":{"delete_articles_by_pk":{"id":11}}}
      ),
    )

    // 存在しない行の update は null
    let missing = run(
      (
        #|mutation {
        #|  update_articles_by_pk(id: 999, _set: {title: "X"}) { id }
        #|}
      ),
    )
    inspect(
      missing,
      content=(
        #|{"data":{"update_articles_by_pk":null}}
      ),
    )
    executor.client.close()
  })
}

///|
async test "M6 E2E: 非 admin ロールはミューテーション不可" {
  let response = run_graphql_as(
    "m6p",
    user_session("1"),
    "mutation { insert_articles(objects: [{id: 99, title: \"x\", author_id: 1}]) { affected_rows } }",
  )
  inspect(
    response,
    content=(
      #|{"errors":[{"message":"no such field on type mutation_root: insert_articles"}]}
    ),
  )
}
