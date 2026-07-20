// V2 風 CRUD の SQL 構築 (INSERT / UPDATE / DELETE を CTE に包み、
// RETURNING を json_agg で 1 行 1 カラムにして返す)

///|
fn literal_expr(
  metadata : PgMetadata,
  ty : PgType,
  value : Json,
) -> Expression raise TranslateError {
  let env : Env = { metadata, relationships: Map([]), variables_table: None }
  let state : State = { global_table_index: 1000 }
  values_translate(env, state, value, ty)
}

///|
fn returning_sql(
  sql : SQL,
  metadata : PgMetadata,
  collection : String,
  returning : Array[(String, String)],
) -> Unit raise TranslateError {
  sql.append_syntax(" RETURNING ")
  if returning.is_empty() {
    sql.append_syntax("1 AS \"__count\"")
    return
  }
  let table = match metadata.tables.get(collection) {
    Some(t) => t
    None => raise CollectionNotFound(collection)
  }
  for i, pair in returning {
    let (alias_, ndc_col) = pair
    let col = match table.columns.get(ndc_col) {
      Some(c) => c
      None => raise ColumnNotFound(column=ndc_col, collection~)
    }
    sql.append_identifier(col.name)
    sql.append_syntax(" AS ")
    sql.append_identifier(alias_)
    if i < returning.length() - 1 {
      sql.append_syntax(", ")
    }
  }
}

///|
/// post-write 権限 CHECK のフラグ列名。書き込み後の行が check 述語を
/// 満たさない場合に true になる。engine はこのフラグを見て
/// ミューテーション全体を拒否 (ROLLBACK) する
pub let check_violation_field : String = "%check__violation"

///|
fn wrap_mutation_cte(
  sql : SQL,
  build_inner : (SQL) -> Unit raise TranslateError,
) -> Unit raise TranslateError {
  sql.append_syntax("WITH \"mut\" AS (")
  build_inner(sql)
  sql.append_syntax(
    ") SELECT coalesce(json_agg(row_to_json(\"mut\")), '[]') AS \"rows\" FROM \"mut\"",
  )
}

///|
/// RETURNING に post-write CHECK のフラグ列を追加する。
/// 述語は書き込み後の行 (INSERT の挿入値 / UPDATE の更新後値) を参照する
fn check_flag_sql(
  sql : SQL,
  metadata : PgMetadata,
  collection : String,
  check : NdcExpression?,
) -> Unit raise TranslateError {
  match check {
    None => ()
    Some(predicate) => {
      let table = metadata.tables.get(collection).unwrap()
      let env : Env = {
        metadata,
        relationships: Map([]),
        variables_table: None,
      }
      let state : State = { global_table_index: 3000 }
      let scope = TableScope::new({
        collection,
        reference: DBTable(
          schema=SchemaName(table.schema_name),
          table=TableName(table.table_name),
        ),
      })
      let expr = filtering_translate(env, state, scope, predicate)
      sql.append_syntax(", NOT (")
      normalize_expr(expr).to_sql(sql)
      sql.append_syntax(") AS ")
      sql.append_identifier(check_violation_field)
    }
  }
}

///|
/// INSERT INTO ... VALUES ... RETURNING → json rows
pub fn build_insert_sql(
  metadata : PgMetadata,
  collection : String,
  rows : Array[Array[(String, Json)]],
  returning : Array[(String, String)],
  check? : NdcExpression? = None,
) -> SQL raise TranslateError {
  let table = match metadata.tables.get(collection) {
    Some(t) => t
    None => raise CollectionNotFound(collection)
  }
  // カラム集合 = 全行のキーの和集合 (最初に出現した順を保持)。行ごとに
  // 欠けているカラムは VALUES で DEFAULT を入れる。以前は rows[0] のキーのみを
  // 使っており、後続行だけが持つカラムの値が黙って落ちていた (#20)。
  let columns : Array[String] = []
  let seen : Map[String, Bool] = Map([])
  for row in rows {
    for pair in row {
      if !seen.contains(pair.0) {
        seen[pair.0] = true
        columns.push(pair.0)
      }
    }
  }
  let sql = SQL::new()
  wrap_mutation_cte(sql, fn(sql) raise TranslateError {
    sql.append_syntax("INSERT INTO ")
    sql.append_identifier(table.schema_name)
    sql.append_syntax(".")
    sql.append_identifier(table.table_name)
    sql.append_syntax(" (")
    for i, ndc_col in columns {
      let col = match table.columns.get(ndc_col) {
        Some(c) => c
        None => raise ColumnNotFound(column=ndc_col, collection~)
      }
      sql.append_identifier(col.name)
      if i < columns.length() - 1 {
        sql.append_syntax(", ")
      }
    }
    sql.append_syntax(") VALUES ")
    for ri, row in rows {
      sql.append_syntax("(")
      for ci, ndc_col in columns {
        let col = table.columns.get(ndc_col).unwrap()
        let mut value : Json = Json::null()
        let mut found = false
        for pair in row {
          if pair.0 == ndc_col {
            value = pair.1
            found = true
          }
        }
        if found {
          literal_expr(metadata, col.ty, value).to_sql(sql)
        } else {
          sql.append_syntax("DEFAULT")
        }
        if ci < columns.length() - 1 {
          sql.append_syntax(", ")
        }
      }
      sql.append_syntax(")")
      if ri < rows.length() - 1 {
        sql.append_syntax(", ")
      }
    }
    returning_sql(sql, metadata, collection, returning)
    check_flag_sql(sql, metadata, collection, check)
  })
  sql
}

///|
fn pk_where_sql(
  sql : SQL,
  metadata : PgMetadata,
  collection : String,
  pk : Array[(String, Json)],
) -> Unit raise TranslateError {
  let table = metadata.tables.get(collection).unwrap()
  sql.append_syntax(" WHERE ")
  for i, pair in pk {
    let (ndc_col, value) = pair
    let col = match table.columns.get(ndc_col) {
      Some(c) => c
      None => raise ColumnNotFound(column=ndc_col, collection~)
    }
    sql.append_syntax("(")
    sql.append_identifier(col.name)
    sql.append_syntax(" = ")
    literal_expr(metadata, col.ty, value).to_sql(sql)
    sql.append_syntax(")")
    if i < pk.length() - 1 {
      sql.append_syntax(" AND ")
    }
  }
}

///|
/// UPDATE ... SET ... WHERE pk RETURNING → json rows
pub fn build_update_by_pk_sql(
  metadata : PgMetadata,
  collection : String,
  pk : Array[(String, Json)],
  set_ : Array[(String, Json)],
  returning : Array[(String, String)],
  filter? : NdcExpression? = None,
  check? : NdcExpression? = None,
) -> SQL raise TranslateError {
  let table = match metadata.tables.get(collection) {
    Some(t) => t
    None => raise CollectionNotFound(collection)
  }
  let sql = SQL::new()
  wrap_mutation_cte(sql, fn(sql) raise TranslateError {
    sql.append_syntax("UPDATE ")
    sql.append_identifier(table.schema_name)
    sql.append_syntax(".")
    sql.append_identifier(table.table_name)
    sql.append_syntax(" SET ")
    for i, pair in set_ {
      let (ndc_col, value) = pair
      let col = match table.columns.get(ndc_col) {
        Some(c) => c
        None => raise ColumnNotFound(column=ndc_col, collection~)
      }
      sql.append_identifier(col.name)
      sql.append_syntax(" = ")
      literal_expr(metadata, col.ty, value).to_sql(sql)
      if i < set_.length() - 1 {
        sql.append_syntax(", ")
      }
    }
    pk_where_sql(sql, metadata, collection, pk)
    permission_filter_sql(sql, metadata, collection, filter)
    returning_sql(sql, metadata, collection, returning)
    check_flag_sql(sql, metadata, collection, check)
  })
  sql
}

///|
/// DELETE ... WHERE pk RETURNING → json rows
pub fn build_delete_by_pk_sql(
  metadata : PgMetadata,
  collection : String,
  pk : Array[(String, Json)],
  returning : Array[(String, String)],
  filter? : NdcExpression? = None,
) -> SQL raise TranslateError {
  let table = match metadata.tables.get(collection) {
    Some(t) => t
    None => raise CollectionNotFound(collection)
  }
  let sql = SQL::new()
  wrap_mutation_cte(sql, fn(sql) raise TranslateError {
    sql.append_syntax("DELETE FROM ")
    sql.append_identifier(table.schema_name)
    sql.append_syntax(".")
    sql.append_identifier(table.table_name)
    pk_where_sql(sql, metadata, collection, pk)
    permission_filter_sql(sql, metadata, collection, filter)
    returning_sql(sql, metadata, collection, returning)
  })
  sql
}

///|
/// ロールの行フィルタを WHERE に AND する (M6)。
/// UPDATE/DELETE の WHERE 内でテーブルを直接参照する
fn permission_filter_sql(
  sql : SQL,
  metadata : PgMetadata,
  collection : String,
  filter : NdcExpression?,
) -> Unit raise TranslateError {
  match filter {
    None => ()
    Some(predicate) => {
      let table = metadata.tables.get(collection).unwrap()
      let env : Env = {
        metadata,
        relationships: Map([]),
        variables_table: None,
      }
      let state : State = { global_table_index: 2000 }
      let scope = TableScope::new({
        collection,
        reference: DBTable(
          schema=SchemaName(table.schema_name),
          table=TableName(table.table_name),
        ),
      })
      let expr = filtering_translate(env, state, scope, predicate)
      sql.append_syntax(" AND (")
      normalize_expr(expr).to_sql(sql)
      sql.append_syntax(")")
    }
  }
}
