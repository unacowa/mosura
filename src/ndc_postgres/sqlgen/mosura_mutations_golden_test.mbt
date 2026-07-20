// Mosura 独自 CRUD SQL のゴールデン (fixtures/mosura/mutations)。
//
// ndc-postgres の mutation/v2 とは SQL 形状が異なる (CTE + json_agg 方式) ため、
// 移植元ゴールデンではなく Mosura 自身の生成 SQL を固定して回帰を防ぐ
// (issue #8 の判断。docs/implementation-plan.md 参照)。
// 期待ファイルを更新する場合は生成 SQL の変更が意図的であることを確認すること。

///|
fn mutations_test_metadata() -> PgMetadata {
  let columns : Map[String, PgColumn] = Map([])
  columns["id"] = { name: "id", ty: TScalar("int4") }
  columns["title"] = { name: "title", ty: TScalar("text") }
  columns["author_id"] = { name: "author_id", ty: TScalar("int4") }
  columns["published"] = { name: "published", ty: TScalar("bool") }
  let tables : Map[String, PgTable] = Map([])
  tables["articles"] = { schema_name: "public", table_name: "article", columns }
  let scalar_types : Map[String, PgScalarType] = Map([])
  for t in ["int4", "text", "bool"] {
    scalar_types[t] = {
      type_name: t,
      schema_name: None,
      comparison_operators: Map([]),
      type_representation: None,
    }
  }
  { tables, scalar_types }
}

///|
fn run_mosura_mutation_case(name : String) -> SQL raise {
  let meta = mutations_test_metadata()
  match name {
    "insert_single_row" =>
      build_insert_sql(
        meta,
        "articles",
        [
          [
            ("id", Json::number(10)),
            ("title", Json::string("new article")),
            ("author_id", Json::number(1)),
          ],
        ],
        [("id", "id"), ("title", "title")],
      )
    "insert_multi_row_with_default" =>
      build_insert_sql(
        meta,
        "articles",
        [
          [
            ("id", Json::number(10)),
            ("title", Json::string("first")),
            ("published", Json::boolean(true)),
          ],
          [("id", Json::number(11)), ("title", Json::string("second"))],
        ],
        [("id", "id")],
      )
    "insert_empty_returning" =>
      build_insert_sql(
        meta,
        "articles",
        [[("id", Json::number(12)), ("title", Json::string("no returning"))]],
        [],
      )
    "update_by_pk" =>
      build_update_by_pk_sql(
        meta,
        "articles",
        [("id", Json::number(10))],
        [
          ("title", Json::string("updated title")),
          ("published", Json::boolean(false)),
        ],
        [("id", "id"), ("title", "title"), ("published", "published")],
      )
    "delete_by_pk" =>
      build_delete_by_pk_sql(meta, "articles", [("id", Json::number(10))], [
        ("id", "id"),
      ])
    other => fail("unknown mosura mutation case: \{other}")
  }
}

///|
test "mosura mutations goldens (fixtures/mosura/mutations)" {
  let base = "fixtures/mosura/mutations"
  let dirs = @fs.read_dir(base)
  dirs.sort()
  let mut checked = 0
  let failures : Array[String] = []
  for case_name in dirs {
    if !@fs.is_dir("\{base}/\{case_name}") {
      continue
    }
    let sql = run_mosura_mutation_case(case_name)
    let actual = sql.sql + ";\n\n" + params_debug(sql.params) + "\n"
    let expected_path = "\{base}/\{case_name}/expected.sql"
    if !@fs.path_exists(expected_path) {
      // 初回生成用: 期待ファイルが無ければ内容を出力して失敗させる
      println("MISSING \{expected_path} — actual output:")
      println(actual)
      failures.push(case_name)
      continue
    }
    let expected = @fs.read_file_to_string(expected_path)
    if actual != expected {
      println("MISMATCH \{case_name} — actual output:")
      println(actual)
      failures.push(case_name)
      continue
    }
    checked += 1
  }
  if failures.length() > 0 {
    fail("golden failures: \{failures.join(", ")}")
  }
  assert_eq(checked, 5)
}
