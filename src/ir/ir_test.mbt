// M3 統合テスト: GraphQL クエリ → (parse → normalize → IR → NDC → sqlgen) → SQL

///|
fn test_metadata() -> @metadata.Metadata raise {
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
    ),
  )
}

///|
fn graphql_to_sql(query : String) -> Array[(String, String)] raise {
  let meta = test_metadata()
  let schema = @schemagen.build_schema(meta)
  let parser = @graphql.Parser::new(@utf8.encode(query))
  let doc = parser.parse_executable_document()
  let op = @schema.normalize_request(AllowAll, schema, {
    query: doc,
    operation_name: None,
    variables: Map([]),
  })
  let pg_meta = to_pg_metadata(meta)
  let plan = plan_operation(meta, pg_meta, @session.Session::admin(), op)
  let out : Array[(String, String)] = []
  for rf in plan {
    match rf {
      RFQuery(alias_~, request~, ..) => {
        let sql = @sqlgen.translate_query_request(pg_meta, request)
        out.push((alias_, sql.sql))
      }
      _ => ()
    }
  }
  out
}

///|
test "M3 E2E: GraphQL → SQL (filter + order + relationship)" {
  let results = graphql_to_sql(
    (
      #|{
      #|  articles(where: {title: {_like: "%moon%"}}, order_by: [{id: Desc}], limit: 3) {
      #|    id
      #|    title
      #|    author { name }
      #|  }
      #|}
    ),
  )
  assert_eq(results.length(), 1)
  let (alias_, sql) = results[0]
  assert_eq(alias_, "articles")
  inspect(
    sql,
    content=(
      #|SELECT coalesce(json_agg(row_to_json("%7_universe")), '[]') AS "universe" FROM (SELECT * FROM (SELECT coalesce(json_agg(row_to_json("%8_rows")), '[]') AS "rows" FROM (SELECT "%1_articles"."id" AS "id", "%1_articles"."title" AS "title", "%2_RELATIONSHIP_author"."author" AS "author" FROM (SELECT "%0_articles".* FROM "public"."articles" AS "%0_articles" WHERE ("%0_articles"."title" LIKE cast($1 as "text")) ORDER BY "%0_articles"."id" DESC  LIMIT 3) AS "%1_articles" LEFT OUTER JOIN LATERAL (SELECT row_to_json("%2_RELATIONSHIP_author") AS "author" FROM (SELECT * FROM (SELECT coalesce(json_agg(row_to_json("%5_rows")), '[]') AS "rows" FROM (SELECT "%4_authors"."name" AS "name" FROM (SELECT "%3_authors".* FROM "public"."authors" AS "%3_authors" WHERE ("%1_articles"."author_id" = "%3_authors"."id") LIMIT 1) AS "%4_authors") AS "%5_rows") AS "%5_rows") AS "%2_RELATIONSHIP_author") AS "%2_RELATIONSHIP_author" ON ('true')  ORDER BY "%1_articles"."id" DESC ) AS "%8_rows") AS "%8_rows") AS "%7_universe"
    ),
  )
}

///|
test "M3 E2E: by_pk クエリ" {
  let results = graphql_to_sql("{ articles_by_pk(id: 42) { title } }")
  let (alias_, sql) = results[0]
  assert_eq(alias_, "articles_by_pk")
  assert_true(sql.contains("\"id\" = 42") || sql.contains("= 42"))
  assert_true(sql.contains("LIMIT 1"))
}
