// テキスト検索演算子が正しい SQL 演算子へ翻訳されることの確認 (#34)。
// すべて infix なので `<column> <OP> <value>` の形になる

///|
fn text_op_metadata() -> PgMetadata {
  let columns : Map[String, PgColumn] = Map([])
  columns["title"] = { name: "title", ty: TScalar("text") }
  let tables : Map[String, PgTable] = Map([])
  tables["articles"] = { schema_name: "public", table_name: "article", columns }
  let scalar_types : Map[String, PgScalarType] = Map([])
  let ops : Map[String, PgComparisonOperator] = Map([])
  let mk = (n : String) => PgComparisonOperator::{
    operator_name: n,
    operator_kind: "custom",
    argument_type: "text",
    is_infix: true,
  }
  ops["_like"] = mk("LIKE")
  ops["_nlike"] = mk("NOT LIKE")
  ops["_ilike"] = mk("ILIKE")
  ops["_similar"] = mk("SIMILAR TO")
  ops["_regex"] = mk("~")
  ops["_niregex"] = mk("!~*")
  scalar_types["text"] = {
    type_name: "text",
    schema_name: None,
    comparison_operators: ops,
    type_representation: None,
  }
  { tables, scalar_types }
}

///|
fn translate_text_op(op : String) -> String raise {
  let request : QueryRequest = {
    collection: "articles",
    query: {
      fields: Some({ "title": FColumn(column="title") }),
      limit: None,
      offset: None,
      predicate: Some(
        EBinary(
          column={ name: "title", path: [] },
          operator=op,
          value=CVScalar(Json::string("x%")),
        ),
      ),
      order_by: None,
    },
    arguments: Map([]),
    collection_relationships: Map([]),
    variables: None,
  }
  translate_query_request(text_op_metadata(), request).sql
}

///|
test "text operators translate to the expected SQL operator" {
  // 生成 SQL に期待する演算子トークンが現れることを確認する
  let cases = [
    ("_like", " LIKE "),
    ("_nlike", " NOT LIKE "),
    ("_ilike", " ILIKE "),
    ("_similar", " SIMILAR TO "),
    ("_regex", " ~ "),
    ("_niregex", " !~* "),
  ]
  for c in cases {
    let (op, token) = c
    let sql = translate_text_op(op)
    assert_true(sql.contains(token))
  }
}
