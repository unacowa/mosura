// ndc-postgres query-engine/sql/src/sql/convert.rs の移植 (AST → SQL 文字列)

///|
pub fn Select::to_sql(self : Select, sql : SQL) -> Unit {
  if !self.with_.is_empty() {
    sql.append_syntax("WITH ")
    for index, cte in self.with_ {
      cte.alias_.to_sql(sql)
      sql.append_syntax(" AS (")
      match cte.select {
        CTSelect(s) => s.to_sql(sql)
        CTDelete(d) => d.to_sql(sql)
        CTInsert(i) => i.to_sql(sql)
        CTUpdate(u) => u.to_sql(sql)
      }
      sql.append_syntax("\n)")
      if index < self.with_.length() - 1 {
        sql.append_syntax(", ")
      }
    }
  }
  sql.append_syntax("SELECT ")
  self.select_list.to_sql(sql)
  sql.append_syntax(" ")
  match self.from {
    Some(from) => from.to_sql(sql)
    None => ()
  }
  for join in self.joins {
    join.to_sql(sql)
  }
  // WHERE (true の場合は省略)
  if !(self.where_ is Value(VBool(true))) {
    sql.append_syntax(" WHERE ")
    self.where_.to_sql(sql)
  }
  if !self.order_by.is_empty() {
    sql.append_syntax(" ORDER BY ")
    for index, element in self.order_by {
      element.target.to_sql(sql)
      match element.direction {
        Asc => sql.append_syntax(" ASC ")
        Desc => sql.append_syntax(" DESC ")
      }
      if index < self.order_by.length() - 1 {
        sql.append_syntax(", ")
      }
    }
  }
  match self.limit {
    Some(limit) => {
      sql.append_syntax(" LIMIT ")
      sql.append_syntax(limit.to_string())
    }
    None => ()
  }
  match self.offset {
    Some(offset) => {
      sql.append_syntax(" OFFSET ")
      sql.append_syntax(offset.to_string())
    }
    None => ()
  }
}

///|
pub fn SelectList::to_sql(self : SelectList, sql : SQL) -> Unit {
  match self {
    SelectListComposite(l1, l2) => {
      l1.to_sql(sql)
      sql.append_syntax(", ")
      l2.to_sql(sql)
    }
    SelectList(items) =>
      for index, item in items {
        let (col, expr) = item
        expr.to_sql(sql)
        sql.append_syntax(" AS ")
        col.to_sql(sql)
        if index < items.length() - 1 {
          sql.append_syntax(", ")
        }
      }
    SelectStar => sql.append_syntax("*")
    SelectStarFrom(table_reference) => {
      table_reference.to_sql(sql)
      sql.append_syntax(".*")
    }
    Select1 => sql.append_syntax("1")
  }
}

///|
pub fn SqlFrom::to_sql(self : SqlFrom, sql : SQL) -> Unit {
  sql.append_syntax("FROM ")
  match self {
    FromTable(reference~, alias_~) => {
      reference.to_sql(sql)
      sql.append_syntax(" AS ")
      alias_.to_sql(sql)
    }
    FromSelect(select~, alias_~) => {
      sql.append_syntax("(")
      select.to_sql(sql)
      sql.append_syntax(")")
      sql.append_syntax(" AS ")
      alias_.to_sql(sql)
    }
    FromUnnest(expression~, alias_~, columns~) => {
      sql.append_syntax("UNNEST")
      sql.append_syntax("(")
      expression.to_sql(sql)
      sql.append_syntax(")")
      sql.append_syntax(" AS ")
      alias_.to_sql(sql)
      if !columns.is_empty() {
        sql.append_syntax("(")
        for index, column in columns {
          column.to_sql(sql)
          if index < columns.length() - 1 {
            sql.append_syntax(", ")
          }
        }
        sql.append_syntax(")")
      }
    }
    FromJsonbArrayElements(expression~, alias_~, column~) => {
      sql.append_syntax("jsonb_array_elements")
      sql.append_syntax("(")
      expression.to_sql(sql)
      sql.append_syntax(")")
      sql.append_syntax(" AS ")
      alias_.to_sql(sql)
      sql.append_syntax("(")
      column.to_sql(sql)
      sql.append_syntax(")")
    }
    FromJsonbToRecordset(expression~, alias_~, columns~) => {
      sql.append_syntax("jsonb_to_recordset")
      sql.append_syntax("(")
      expression.to_sql(sql)
      sql.append_syntax(")")
      sql.append_syntax(" AS ")
      alias_.to_sql(sql)
      sql.append_syntax("(")
      for index, item in columns {
        let (column, scalar_type) = item
        column.to_sql(sql)
        sql.append_syntax(" ")
        sql.append_identifier(scalar_type)
        if index < columns.length() - 1 {
          sql.append_syntax(", ")
        }
      }
      sql.append_syntax(")")
    }
  }
}

///|
pub fn Join::to_sql(self : Join, sql : SQL) -> Unit {
  match self {
    LeftOuterJoinLateral(select~, alias_~) => {
      sql.append_syntax(" LEFT OUTER JOIN LATERAL ")
      sql.append_syntax("(")
      select.to_sql(sql)
      sql.append_syntax(")")
      sql.append_syntax(" AS ")
      alias_.to_sql(sql)
      sql.append_syntax(" ON ('true') ")
    }
    InnerJoinLateral(select~, alias_~) => {
      sql.append_syntax(" INNER JOIN LATERAL ")
      sql.append_syntax("(")
      select.to_sql(sql)
      sql.append_syntax(")")
      sql.append_syntax(" AS ")
      alias_.to_sql(sql)
      sql.append_syntax(" ON ('true') ")
    }
    FullOuterJoinLateral(select~, alias_~) => {
      sql.append_syntax(" FULL OUTER JOIN LATERAL ")
      sql.append_syntax("(")
      select.to_sql(sql)
      sql.append_syntax(")")
      sql.append_syntax(" AS ")
      alias_.to_sql(sql)
      sql.append_syntax(" ON ('true') ")
    }
    CrossJoinLateral(select~, alias_~) => {
      sql.append_syntax(" CROSS JOIN LATERAL ")
      sql.append_syntax("(")
      select.to_sql(sql)
      sql.append_syntax(")")
      sql.append_syntax(" AS ")
      alias_.to_sql(sql)
    }
    CrossJoin(select~, alias_~) => {
      sql.append_syntax(" CROSS JOIN ")
      sql.append_syntax("(")
      select.to_sql(sql)
      sql.append_syntax(")")
      sql.append_syntax(" AS ")
      alias_.to_sql(sql)
    }
  }
}

///|
pub fn Expression::to_sql(self : Expression, sql : SQL) -> Unit {
  match self {
    ColumnReference(column_reference) => column_reference.to_sql(sql)
    Value(value) => value.to_sql(sql)
    Cast(expression~, ty~) => {
      sql.append_syntax("cast")
      sql.append_syntax("(")
      expression.to_sql(sql)
      sql.append_syntax(" as ")
      match ty.schema {
        Some(schema) => {
          sql.append_identifier(schema)
          sql.append_syntax(".")
        }
        None => ()
      }
      sql.append_identifier(ty.name)
      if ty.is_array {
        sql.append_syntax("[]")
      }
      sql.append_syntax(")")
    }
    And(left~, right~) => {
      sql.append_syntax("(")
      left.to_sql(sql)
      sql.append_syntax(" AND ")
      right.to_sql(sql)
      sql.append_syntax(")")
    }
    Or(left~, right~) => {
      sql.append_syntax("(")
      left.to_sql(sql)
      sql.append_syntax(" OR ")
      right.to_sql(sql)
      sql.append_syntax(")")
    }
    Not(expr) => {
      sql.append_syntax("NOT ")
      expr.to_sql(sql)
    }
    BinaryOperation(left~, operator~, right~) => {
      sql.append_syntax("(")
      left.to_sql(sql)
      sql.append_syntax(" ")
      sql.append_syntax(operator)
      sql.append_syntax(" ")
      right.to_sql(sql)
      sql.append_syntax(")")
    }
    BinaryArrayOperation(left~, operator~, right~) => {
      sql.append_syntax("(")
      left.to_sql(sql)
      sql.append_syntax(" ")
      sql.append_syntax(operator)
      sql.append_syntax(" ")
      sql.append_syntax("(")
      for index, item in right {
        item.to_sql(sql)
        if index < right.length() - 1 {
          sql.append_syntax(", ")
        }
      }
      sql.append_syntax(")")
      sql.append_syntax(")")
    }
    UnaryOperation(expression~, operator~) => {
      sql.append_syntax("(")
      expression.to_sql(sql)
      sql.append_syntax(" ")
      sql.append_syntax(operator)
      sql.append_syntax(" ")
      sql.append_syntax(")")
    }
    FunctionCall(function~, args~) => {
      sql.append_syntax(function)
      sql.append_syntax("(")
      for index, arg in args {
        arg.to_sql(sql)
        if index < args.length() - 1 {
          sql.append_syntax(", ")
        }
      }
      sql.append_syntax(")")
    }
    Exists(select~) => {
      sql.append_syntax("EXISTS ")
      sql.append_syntax("(")
      select.to_sql(sql)
      sql.append_syntax(")")
    }
    JsonBuildObject(map) => {
      sql.append_syntax("json_build_object")
      sql.append_syntax("(")
      for index, item in map {
        let (label, expr) = item
        sql.append_syntax("'")
        sql.append_syntax(label)
        sql.append_syntax("'")
        sql.append_syntax(", ")
        expr.to_sql(sql)
        if index < map.length() - 1 {
          sql.append_syntax(", ")
        }
      }
      sql.append_syntax(")")
    }
    RowToJson(table_reference) => {
      sql.append_syntax("row_to_json")
      sql.append_syntax("(")
      table_reference.to_sql(sql)
      sql.append_syntax(")")
    }
    CorrelatedSubSelect(select) => {
      sql.append_syntax("(")
      select.to_sql(sql)
      sql.append_syntax(")")
    }
  }
}

///|
pub fn SqlValue::to_sql(self : SqlValue, sql : SQL) -> Unit {
  match self {
    EmptyJsonArray => sql.append_syntax("'[]'")
    VInt4(i) => sql.append_syntax(i.to_string())
    VFloat8(n) => sql.append_syntax(rust_f64_to_string(n))
    VString(s) => sql.append_param(PString(s))
    VVariable(v) => sql.append_param(PVariable(v))
    VBool(true) => sql.append_syntax("true")
    VBool(false) => sql.append_syntax("false")
    VNull => sql.append_syntax("null")
    VJsonValue(v) => sql.append_param(PValue(v))
    VArray(items) => {
      sql.append_syntax("ARRAY [")
      for index, item in items {
        item.to_sql(sql)
        if index < items.length() - 1 {
          sql.append_syntax(", ")
        }
      }
      sql.append_syntax("]")
    }
  }
}

///|
/// Rust の f64 Display 相当 (整数値は小数点なし)
pub fn rust_f64_to_string(f : Double) -> String {
  f.to_string()
}

///|
pub fn TableReference::to_sql(self : TableReference, sql : SQL) -> Unit {
  match self {
    DBTable(schema~, table~) => {
      sql.append_identifier(schema.0)
      sql.append_syntax(".")
      sql.append_identifier(table.0)
    }
    AliasedTable(alias_) => alias_.to_sql(sql)
  }
}

///|
pub fn TableAlias::to_sql(self : TableAlias, sql : SQL) -> Unit {
  sql.append_identifier("%\{self.unique_index}_\{self.name}")
}

///|
pub fn ColumnReference::to_sql(self : ColumnReference, sql : SQL) -> Unit {
  match self {
    TableColumn(table~, name~) => {
      table.to_sql(sql)
      sql.append_syntax(".")
      sql.append_identifier(name.0)
    }
    AliasedColumn(table~, column~) => {
      table.to_sql(sql)
      sql.append_syntax(".")
      column.to_sql(sql)
    }
  }
}

///|
pub fn ColumnAlias::to_sql(self : ColumnAlias, sql : SQL) -> Unit {
  sql.append_identifier(self.0)
}

///|
pub fn Delete::to_sql(self : Delete, sql : SQL) -> Unit {
  sql.append_syntax("DELETE ")
  sql.append_syntax("FROM ")
  sql.append_identifier(self.from_schema.0)
  sql.append_syntax(".")
  sql.append_identifier(self.from_table.0)
  sql.append_syntax(" AS ")
  self.from_alias.to_sql(sql)
  sql.append_syntax(" ")
  if !(self.where_ is Value(VBool(true))) {
    sql.append_syntax(" WHERE ")
    self.where_.to_sql(sql)
  }
  sql.append_syntax(" ")
  sql.append_syntax("RETURNING ")
  self.returning.to_sql(sql)
}

///|
pub fn Insert::to_sql(self : Insert, sql : SQL) -> Unit {
  sql.append_syntax("INSERT INTO ")
  sql.append_identifier(self.schema.0)
  sql.append_syntax(".")
  sql.append_identifier(self.table.0)
  match self.columns {
    Some(columns) => {
      sql.append_syntax("(")
      for index, column_name in columns {
        sql.append_identifier(column_name.0)
        if index < columns.length() - 1 {
          sql.append_syntax(", ")
        }
      }
      sql.append_syntax(")")
    }
    None => ()
  }
  sql.append_syntax(" ")
  sql.append_syntax("VALUES ")
  for index, object in self.values {
    sql.append_syntax("(")
    for vindex, value in object {
      match value {
        DefaultValue => sql.append_syntax("DEFAULT")
        MutExpression(e) => e.to_sql(sql)
      }
      if vindex < object.length() - 1 {
        sql.append_syntax(", ")
      }
    }
    sql.append_syntax(")")
    if index < self.values.length() - 1 {
      sql.append_syntax(", ")
    }
  }
  sql.append_syntax(" ")
  sql.append_syntax("RETURNING ")
  self.returning.to_sql(sql)
}

///|
pub fn Update::to_sql(self : Update, sql : SQL) -> Unit {
  sql.append_syntax("UPDATE ")
  sql.append_identifier(self.schema.0)
  sql.append_syntax(".")
  sql.append_identifier(self.table.0)
  sql.append_syntax(" SET ")
  for index, item in self.set_ {
    let (column, expression) = item
    sql.append_identifier(column.0)
    sql.append_syntax(" = ")
    match expression {
      DefaultValue => sql.append_syntax("DEFAULT")
      MutExpression(e) => e.to_sql(sql)
    }
    if index < self.set_.length() - 1 {
      sql.append_syntax(", ")
    }
  }
  sql.append_syntax(" ")
  if !(self.where_ is Value(VBool(true))) {
    sql.append_syntax(" WHERE ")
    self.where_.to_sql(sql)
  }
  sql.append_syntax(" ")
  sql.append_syntax("RETURNING ")
  self.returning.to_sql(sql)
}
