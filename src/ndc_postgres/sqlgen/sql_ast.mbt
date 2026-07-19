// ndc-postgres query-engine/sql/src/sql/{string,ast}.rs の移植

///|
/// パラメタライズドクエリのパラメータ
pub(all) enum Param {
  PString(String)
  PValue(Json)
  PVariable(String)
} derive(Eq)

///|
/// 生成された SQL 文字列とパラメータ列
pub(all) struct SQL {
  mut sql : String
  params : Array[Param]
}

///|
pub fn SQL::new() -> SQL {
  { sql: "", params: [] }
}

///|
pub fn SQL::append_syntax(self : SQL, sql : String) -> Unit {
  self.sql = self.sql + sql
}

///|
pub fn SQL::append_identifier(self : SQL, sql : String) -> Unit {
  self.sql = self.sql + "\"" + sql + "\""
}

///|
pub fn SQL::append_param(self : SQL, param : Param) -> Unit {
  self.params.push(param)
  self.sql = self.sql + "$" + self.params.length().to_string()
}

// --- AST ---

///|
pub(all) struct Select {
  mut with_ : Array[CommonTableExpression]
  mut select_list : SelectList
  mut from : SqlFrom?
  mut joins : Array[Join]
  mut where_ : Expression
  mut order_by : Array[OrderByElement]
  mut limit : Int?
  mut offset : Int?
}

///|
pub(all) struct CommonTableExpression {
  alias_ : TableAlias
  select : CTExpr
}

///|
pub(all) enum CTExpr {
  CTSelect(Select)
  CTDelete(Delete)
  CTInsert(Insert)
  CTUpdate(Update)
}

///|
pub(all) enum SelectList {
  SelectList(Array[(ColumnAlias, Expression)])
  SelectStar
  SelectStarFrom(TableReference)
  Select1
  SelectListComposite(SelectList, SelectList)
}

///|
pub(all) enum SqlFrom {
  FromTable(reference~ : TableReference, alias_~ : TableAlias)
  FromSelect(select~ : Select, alias_~ : TableAlias)
  FromUnnest(
    expression~ : Expression,
    alias_~ : TableAlias,
    columns~ : Array[ColumnAlias]
  )
  FromJsonbToRecordset(
    expression~ : Expression,
    alias_~ : TableAlias,
    columns~ : Array[(ColumnAlias, String)]
  )
  FromJsonbArrayElements(
    expression~ : Expression,
    alias_~ : TableAlias,
    column~ : ColumnAlias
  )
}

///|
pub(all) enum Join {
  LeftOuterJoinLateral(select~ : Select, alias_~ : TableAlias)
  InnerJoinLateral(select~ : Select, alias_~ : TableAlias)
  FullOuterJoinLateral(select~ : Select, alias_~ : TableAlias)
  CrossJoinLateral(select~ : Select, alias_~ : TableAlias)
  CrossJoin(select~ : Select, alias_~ : TableAlias)
}

///|
pub(all) struct OrderByElement {
  target : Expression
  direction : OrderByDirection
}

///|
pub(all) enum OrderByDirection {
  Asc
  Desc
} derive(Eq)

///|
pub(all) enum Expression {
  And(left~ : Expression, right~ : Expression)
  Or(left~ : Expression, right~ : Expression)
  Not(Expression)
  BinaryOperation(left~ : Expression, operator~ : String, right~ : Expression)
  BinaryArrayOperation(
    left~ : Expression,
    operator~ : String,
    right~ : Array[Expression]
  )
  UnaryOperation(expression~ : Expression, operator~ : String)
  FunctionCall(function~ : String, args~ : Array[Expression])
  Exists(select~ : Select)
  JsonBuildObject(Array[(String, Expression)])
  RowToJson(TableReference)
  ColumnReference(ColumnReference)
  Value(SqlValue)
  Cast(expression~ : Expression, ty~ : CastType)
  CorrelatedSubSelect(Select)
}

///|
/// cast の型 (schema 修飾と配列サフィックス)
pub(all) struct CastType {
  schema : String?
  name : String
  is_array : Bool
} derive(Eq)

///|
pub(all) enum SqlValue {
  VInt4(Int)
  VFloat8(Double)
  VBool(Bool)
  VString(String)
  VNull
  VArray(Array[SqlValue])
  VJsonValue(Json)
  EmptyJsonArray
  VVariable(String)
} derive(Eq)

///|
pub(all) struct SchemaName(String) derive(Eq)

///|
pub(all) struct TableName(String) derive(Eq)

///|
pub(all) enum TableReference {
  DBTable(schema~ : SchemaName, table~ : TableName)
  AliasedTable(TableAlias)
} derive(Eq)

///|
pub(all) struct ColumnName(String) derive(Eq)

///|
pub(all) enum ColumnReference {
  TableColumn(table~ : TableReference, name~ : ColumnName)
  AliasedColumn(table~ : TableReference, column~ : ColumnAlias)
} derive(Eq)

///|
pub(all) struct TableAlias {
  unique_index : Int
  name : String
} derive(Eq)

///|
pub(all) struct ColumnAlias(String) derive(Eq)

///|
pub(all) struct Delete {
  from_schema : SchemaName
  from_table : TableName
  from_alias : TableAlias
  where_ : Expression
  returning : SelectList
}

///|
pub(all) struct Insert {
  schema : SchemaName
  table : TableName
  columns : Array[ColumnName]?
  values : Array[Array[MutationValueExpression]]
  returning : SelectList
}

///|
pub(all) enum MutationValueExpression {
  DefaultValue
  MutExpression(Expression)
}

///|
pub(all) struct Update {
  schema : SchemaName
  table : TableName
  set_ : Array[(ColumnName, MutationValueExpression)]
  where_ : Expression
  returning : SelectList
}
