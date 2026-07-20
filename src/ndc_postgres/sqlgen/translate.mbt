// ndc-postgres query-engine/translation の移植 (query パス)
// root.rs / fields.rs / filtering.rs / sorting.rs (単純カラムのみ) / relationships.rs / values.rs / variables.rs

///|
pub suberror TranslateError {
  CollectionNotFound(String)
  ColumnNotFound(column~ : String, collection~ : String)
  RelationshipNotFound(String)
  OperatorNotFound(operator~ : String, type_name~ : String)
  ScalarTypeNotFound(String)
  UnexpectedVariable
  ScopeOutOfBounds
  NotImplemented(String)
  TypeMismatch(String)
} derive(Debug)

///|
pub fn TranslateError::display(self : TranslateError) -> String {
  match self {
    CollectionNotFound(c) => "Collection '\{c}' not found."
    ColumnNotFound(column~, collection~) =>
      "Column '\{column}' not found in collection '\{collection}'."
    RelationshipNotFound(r) => "Relationship '\{r}' not found."
    OperatorNotFound(operator~, type_name~) =>
      "Operator '\{operator}' not found in type \{type_name}."
    ScalarTypeNotFound(t) => "Scalar Type '\{t}' not found."
    UnexpectedVariable =>
      "Unexpected variable in a query request which does not contain variables."
    ScopeOutOfBounds => "Scope out of bounds."
    NotImplemented(s) => "Not implemented: \{s}."
    TypeMismatch(s) => "Type mismatch: \{s}."
  }
}

// --- 定数 (sql/helpers.rs) ---

///|
pub let variables_object_placeholder : String = "%VARIABLES_OBJECT_PLACEHOLDER"

///|
pub let variable_order_field : String = "%variable_order"

///|
pub let variables_field : String = "%variables"

///|
fn true_expr() -> Expression {
  Value(VBool(true))
}

///|
fn false_expr() -> Expression {
  Value(VBool(false))
}

///|
fn simple_select(select_list : Array[(ColumnAlias, Expression)]) -> Select {
  {
    with_: [],
    select_list: SelectList(select_list),
    from: None,
    joins: [],
    where_: true_expr(),
    order_by: [],
    limit: None,
    offset: None,
  }
}

///|
fn star_select(from : SqlFrom) -> Select {
  let s = simple_select([])
  s.select_list = SelectStar
  s.from = Some(from)
  s
}

///|
fn star_from_select(table : TableReference, from : SqlFrom) -> Select {
  let s = simple_select([])
  s.select_list = SelectStarFrom(table)
  s.from = Some(from)
  s
}

///|
fn wrap_in_json_agg(expression : Expression) -> Expression {
  FunctionCall(function="coalesce", args=[
    FunctionCall(function="json_agg", args=[expression]),
    Value(EmptyJsonArray),
  ])
}

///|
fn select_rows_as_json(
  row_select : Select,
  column_alias : ColumnAlias,
  table_alias : TableAlias,
) -> Select {
  let expression = FunctionCall(function="coalesce", args=[
    FunctionCall(function="json_agg", args=[
      RowToJson(AliasedTable(table_alias)),
    ]),
    Value(EmptyJsonArray),
  ])
  let select = simple_select([(column_alias, expression)])
  select.from = Some(FromSelect(select=row_select, alias_=table_alias))
  select
}

///|
fn where_exists_select(
  from : SqlFrom,
  joins : Array[Join],
  where_ : Expression,
) -> Expression {
  let s = simple_select([])
  s.select_list = Select1
  s.from = Some(from)
  s.joins = joins
  s.where_ = where_
  Exists(select=s)
}

///|
fn fold_and_balanced(expressions : Array[Expression]) -> Expression {
  if expressions.is_empty() {
    return true_expr()
  }
  let mut level = expressions
  while level.length() > 1 {
    let next_level : Array[Expression] = []
    let mut i = 0
    while i < level.length() {
      if i + 1 < level.length() {
        next_level.push(And(left=level[i], right=level[i + 1]))
      } else {
        next_level.push(level[i])
      }
      i += 2
    }
    level = next_level
  }
  level[0]
}

///|
fn fold_or_balanced(expressions : Array[Expression]) -> Expression {
  if expressions.is_empty() {
    return false_expr()
  }
  let mut level = expressions
  while level.length() > 1 {
    let next_level : Array[Expression] = []
    let mut i = 0
    while i < level.length() {
      if i + 1 < level.length() {
        next_level.push(Or(left=level[i], right=level[i + 1]))
      } else {
        next_level.push(level[i])
      }
      i += 2
    }
    level = next_level
  }
  level[0]
}

// --- Env / State ---

///|
pub(all) struct Env {
  metadata : PgMetadata
  relationships : Map[String, NdcRelationship]
  variables_table : TableReference?
}

///|
pub(all) struct State {
  mut global_table_index : Int
}

///|
fn State::make_table_alias(self : State, name : String) -> TableAlias {
  let index = self.global_table_index
  self.global_table_index = index + 1
  { unique_index: index, name }
}

///|
fn State::make_relationship_table_alias(
  self : State,
  name : String,
) -> TableAlias {
  self.make_table_alias("RELATIONSHIP_\{name}")
}

///|
fn State::make_boolean_expression_table_alias(
  self : State,
  name : String,
) -> TableAlias {
  self.make_table_alias("BOOLEXP_\{name}")
}

///|
fn Env::lookup_collection(
  self : Env,
  collection_name : String,
) -> PgTable raise TranslateError {
  match self.metadata.tables.get(collection_name) {
    Some(t) => t
    None => raise CollectionNotFound(collection_name)
  }
}

///|
fn Env::lookup_column(
  self : Env,
  collection_name : String,
  column_name : String,
) -> PgColumn raise TranslateError {
  let table = self.lookup_collection(collection_name)
  match table.columns.get(column_name) {
    Some(c) => c
    None => raise ColumnNotFound(column=column_name, collection=collection_name)
  }
}

///|
fn Env::lookup_relationship(
  self : Env,
  name : String,
) -> NdcRelationship raise TranslateError {
  match self.relationships.get(name) {
    Some(r) => r
    None => raise RelationshipNotFound(name)
  }
}

///|
fn Env::lookup_comparison_operator(
  self : Env,
  scalar_type : String,
  name : String,
) -> PgComparisonOperator raise TranslateError {
  match self.metadata.scalar_types.get(scalar_type) {
    Some(t) =>
      match t.comparison_operators.get(name) {
        Some(op) => op
        None => raise OperatorNotFound(operator=name, type_name=scalar_type)
      }
    None => raise OperatorNotFound(operator=name, type_name=scalar_type)
  }
}

///|
fn Env::get_variables_table(self : Env) -> TableReference raise TranslateError {
  match self.variables_table {
    Some(t) => t
    None => raise UnexpectedVariable
  }
}

///|
/// 現在のテーブル (コレクション名 + SQL 上の参照)
pub(all) struct CurrentTable {
  collection : String
  reference : TableReference
}

///|
/// exists 用のスコープ (先頭が現在、以降が外側)
pub(all) struct TableScope {
  current : CurrentTable
  in_scope : Array[CurrentTable]
}

///|
fn TableScope::new(current : CurrentTable) -> TableScope {
  { current, in_scope: [] }
}

///|
fn TableScope::new_from_scope(
  self : TableScope,
  current : CurrentTable,
) -> TableScope {
  let in_scope = [self.current]
  in_scope.append(self.in_scope.copy())
  { current, in_scope }
}

///|
fn TableScope::scoped_table(
  self : TableScope,
  scope : Int?,
) -> CurrentTable raise TranslateError {
  match scope {
    None => self.current
    Some(0) => self.current
    Some(n) =>
      if n > 0 && n <= self.in_scope.length() {
        self.in_scope[n - 1]
      } else {
        raise ScopeOutOfBounds
      }
  }
}

// --- values / variables ---

///|
fn scalar_cast_type(
  env : Env,
  scalar_type : String,
) -> CastType raise TranslateError {
  match env.metadata.scalar_types.get(scalar_type) {
    Some(st) => { schema: st.schema_name, name: st.type_name, is_array: false }
    None => raise ScalarTypeNotFound(scalar_type)
  }
}

///|
fn pg_type_cast_type(env : Env, ty : PgType) -> CastType raise TranslateError {
  match ty {
    TScalar(s) => scalar_cast_type(env, s)
    TArray(TScalar(s)) => {
      let base = scalar_cast_type(env, s)
      { schema: base.schema, name: base.name, is_array: true }
    }
    TArray(_) => raise NotImplemented("nested array types")
    TComposite(_) => raise NotImplemented("composite types")
  }
}

///|
fn make_cast(
  env : Env,
  expr : Expression,
  ty : PgType,
) -> Expression raise TranslateError {
  Cast(expression=expr, ty=pg_type_cast_type(env, ty))
}

///|
/// text 型
fn text_cast(is_array : Bool) -> CastType {
  { schema: None, name: "text", is_array }
}

///|
fn values_translate(
  env : Env,
  state : State,
  value : Json,
  ty : PgType,
) -> Expression raise TranslateError {
  match (value, ty) {
    (Json::Null, _) => make_cast(env, Value(VNull), ty)
    (Json::True, _) => Value(VBool(true))
    (Json::False, _) => Value(VBool(false))
    (Json::Number(n, ..), _) => Value(VFloat8(n))
    (Json::String(s), _) => make_cast(env, Value(VString(s)), ty)
    (Json::Array(_), TArray(_)) =>
      translate_projected(env, state, ty, Value(VJsonValue(value)))
    _ =>
      make_cast(
        env,
        Cast(expression=Value(VJsonValue(value)), ty={
          schema: None,
          name: "jsonb",
          is_array: false,
        }),
        ty,
      )
  }
}

///|
/// JSON 式から型付きの値へ射影する (values.rs::translate_projected)
fn translate_projected(
  env : Env,
  state : State,
  ty : PgType,
  expression : Expression,
) -> Expression raise TranslateError {
  match ty {
    TScalar(_) =>
      make_cast(
        env,
        BinaryOperation(
          left=expression,
          operator="#>>",
          right=Cast(expression=Value(VArray([])), ty=text_cast(true)),
        ),
        ty,
      )
    TArray(element_type) => {
      let array_table = state.make_table_alias("array")
      let element_column = ColumnAlias("element")
      let from_arr = SqlFrom::FromJsonbArrayElements(
        expression~,
        alias_=array_table,
        column=element_column,
      )
      let element_expression = Expression::ColumnReference(
        AliasedColumn(table=AliasedTable(array_table), column=element_column),
      )
      let converted_element_exp = translate_projected(
        env, state, element_type, element_expression,
      )
      let elem_cast = pg_type_cast_type(env, element_type)
      let empty_array = Cast(expression=Value(VArray([])), ty={
        schema: elem_cast.schema,
        name: elem_cast.name,
        is_array: true,
      })
      let result_select = simple_select([
        (
          element_column,
          FunctionCall(function="coalesce", args=[
            FunctionCall(function="array_agg", args=[converted_element_exp]),
            empty_array,
          ]),
        ),
      ])
      result_select.from = Some(from_arr)
      CorrelatedSubSelect(result_select)
    }
    TComposite(_) => raise NotImplemented("composite type projection")
  }
}

///|
fn variables_translate(
  env : Env,
  state : State,
  variables_table : TableReference,
  variable : String,
  ty : PgType,
) -> Expression raise TranslateError {
  let variables_reference = Expression::ColumnReference(
    AliasedColumn(table=variables_table, column=ColumnAlias(variables_field)),
  )
  let projected_variable_exp = BinaryOperation(
    left=variables_reference,
    operator="->",
    right=Value(VString(variable)),
  )
  translate_projected(env, state, ty, projected_variable_exp)
}

// --- fields ---

///|
fn fields_translate(
  env : Env,
  state : State,
  fields : Map[String, NdcField],
  current_table : CurrentTable,
  from : SqlFrom,
  join_relationship_fields : Array[JoinFieldInfo],
) -> Select raise TranslateError {
  let columns : Array[(ColumnAlias, Expression)] = []
  for alias_name, field in fields {
    match field {
      FColumn(column~) => {
        let column_info = env.lookup_column(current_table.collection, column)
        let expr = Expression::ColumnReference(
          TableColumn(
            table=current_table.reference,
            name=ColumnName(column_info.name),
          ),
        )
        // Int64AsString 等は text に cast
        let expr = wrap_in_type_representation(env, expr, column_info.ty)
        columns.push((ColumnAlias(alias_name), expr))
      }
      FRelationship(query~, relationship~, arguments~) => {
        let table_alias = state.make_relationship_table_alias(alias_name)
        let column_alias = ColumnAlias(alias_name)
        columns.push(
          (
            column_alias,
            Expression::ColumnReference(
              AliasedColumn(
                table=AliasedTable(table_alias),
                column=column_alias,
              ),
            ),
          ),
        )
        ignore(arguments)
        join_relationship_fields.push({
          table_alias,
          column_alias,
          relationship_name: relationship,
          query,
        })
      }
    }
  }
  let select = simple_select(columns)
  select.from = Some(from)
  select
}

///|
fn wrap_in_type_representation(
  env : Env,
  expression : Expression,
  ty : PgType,
) -> Expression {
  match ty {
    TScalar(s) =>
      match env.metadata.scalar_types.get(s) {
        Some(st) =>
          match st.type_representation {
            Some("int64AsString") | Some("bigDecimalAsString") =>
              Cast(expression~, ty=text_cast(false))
            _ => expression
          }
        None => expression
      }
    _ => expression
  }
}

// --- relationships ---

///|
priv struct JoinFieldInfo {
  table_alias : TableAlias
  column_alias : ColumnAlias
  relationship_name : String
  query : NdcQuery
}

///|
fn relationships_translate(
  env : Env,
  state : State,
  current_table : CurrentTable,
  join_fields : Array[JoinFieldInfo],
) -> Array[Join] raise TranslateError {
  let joins : Array[Join] = []
  for join_field in join_fields {
    let relationship = env.lookup_relationship(join_field.relationship_name)
    let select_set = translate_query(
      env,
      state,
      MakeFromCollection(relationship.target_collection),
      Some((current_table, relationship)),
      join_field.query,
    )
    let rows_pair = (state.make_table_alias("rows"), ColumnAlias("rows"))
    let _aggregates = state.make_table_alias("aggregates")
    let json_select = select_rowset_without_variables(
      false, // ObjectResults
      (join_field.table_alias, join_field.column_alias),
      rows_pair,
      select_set,
    )
    joins.push(
      LeftOuterJoinLateral(select=json_select, alias_=join_field.table_alias),
    )
  }
  joins
}

///|
fn translate_column_mapping(
  env : Env,
  current_table : CurrentTable,
  target_reference : TableReference,
  expr : Expression,
  relationship : NdcRelationship,
) -> Expression raise TranslateError {
  let mut acc = expr
  for pair in relationship.column_mapping {
    let (source_col, target_col) = pair
    let source_column_info = env.lookup_column(
      current_table.collection,
      source_col,
    )
    let target_column_info = env.lookup_column(
      relationship.target_collection,
      target_col,
    )
    acc = And(
      left=acc,
      right=BinaryOperation(
        left=Expression::ColumnReference(
          TableColumn(
            table=current_table.reference,
            name=ColumnName(source_column_info.name),
          ),
        ),
        operator="=",
        right=Expression::ColumnReference(
          TableColumn(
            table=target_reference,
            name=ColumnName(target_column_info.name),
          ),
        ),
      ),
    )
  }
  acc
}

// --- root ---

///|
priv enum MakeFrom {
  MakeFromCollection(String)
}

///|
fn make_reference_and_from_clause(
  env : Env,
  state : State,
  make_from : MakeFrom,
  collection_alias : TableAlias?,
) -> (CurrentTable, SqlFrom) raise TranslateError {
  match make_from {
    MakeFromCollection(name) => {
      let alias_ = match collection_alias {
        Some(a) => a
        None => state.make_table_alias(name)
      }
      let info = env.lookup_collection(name)
      let db_table = DBTable(
        schema=SchemaName(info.schema_name),
        table=TableName(info.table_name),
      )
      let from_clause = FromTable(reference=db_table, alias_~)
      ({ collection: name, reference: AliasedTable(alias_) }, from_clause)
    }
  }
}

///|
/// SelectSet は rows のみ対応 (aggregates は対象外)
fn translate_query(
  env : Env,
  state : State,
  make_from : MakeFrom,
  join_predicate : (CurrentTable, NdcRelationship)?,
  query : NdcQuery,
) -> Select raise TranslateError {
  // rows_subquery
  let (current_table0, from_clause0) = make_reference_and_from_clause(
    env,
    state,
    make_from,
    None,
  )
  let subquery_scope = TableScope::new(current_table0)
  let subquery_select = star_from_select(current_table0.reference, from_clause0)
  // where + join predicate
  let filter = match query.predicate {
    None => true_expr()
    Some(predicate) =>
      filtering_translate(env, state, subquery_scope, predicate)
  }
  subquery_select.where_ = match join_predicate {
    None => filter
    Some((join_with, relationship)) =>
      translate_column_mapping(
        env,
        join_with,
        current_table0.reference,
        filter,
        relationship,
      )
  }
  // order by / limit: リレーションを跨がない場合はサブクエリに置く。
  // 跨ぐ場合は JOIN が必要なため fields select 側でまとめて処理する
  // (upstream root.rs::order_by_crosses_relationships)
  let mut order_by_crosses_relationships = false
  match query.order_by {
    Some(elements) =>
      for e in elements {
        if !e.target_path.is_empty() {
          order_by_crosses_relationships = true
          break
        }
      }
    None => ()
  }
  if !order_by_crosses_relationships {
    match query.order_by {
      Some(elements) => {
        let (order_by, _joins) = sorting_translate(
          env, state, subquery_scope, elements,
        )
        subquery_select.order_by = order_by
      }
      None => ()
    }
    subquery_select.limit = query.limit
    subquery_select.offset = query.offset
  }

  // rows select
  let alias_ = state.make_table_alias(current_table0.collection)
  let current_table : CurrentTable = {
    collection: current_table0.collection,
    reference: AliasedTable(alias_),
  }
  let from_clause = FromSelect(select=subquery_select, alias_~)
  let join_relationship_fields : Array[JoinFieldInfo] = []
  let fields : Map[String, NdcField] = match query.fields {
    Some(f) => f
    None => Map([])
  }
  let fields_select = fields_translate(
    env, state, fields, current_table, from_clause, join_relationship_fields,
  )
  let relationship_joins = relationships_translate(
    env, state, current_table, join_relationship_fields,
  )
  fields_select.joins.append(relationship_joins)
  // upstream は translate_rows でも sorting を適用する (エイリアスは rows テーブル基準)。
  // リレーションを跨ぐ場合は JOIN と limit/offset もこのレベルに置く
  match query.order_by {
    Some(elements) => {
      let scope = TableScope::new(current_table)
      let (order_by, order_by_joins) = sorting_translate(
        env, state, scope, elements,
      )
      fields_select.order_by = order_by
      if order_by_crosses_relationships {
        fields_select.joins.append(order_by_joins)
        fields_select.limit = query.limit
        fields_select.offset = query.offset
      }
    }
    None => ()
  }
  fields_select
}

///|
/// sql/helpers.rs::select_rowset_without_variables (rows のみ)
fn select_rowset_without_variables(
  aggregate_results : Bool,
  output_pair : (TableAlias, ColumnAlias),
  row_pair : (TableAlias, ColumnAlias),
  row_select : Select,
) -> Select {
  let (output_table_alias, output_column_alias) = output_pair
  let (row_table_alias, row_column_alias) = row_pair
  let output = Expression::RowToJson(AliasedTable(output_table_alias))
  let output = if aggregate_results { wrap_in_json_agg(output) } else { output }
  let final_select = simple_select([(output_column_alias, output)])
  let wrapped = select_rows_as_json(
    row_select, row_column_alias, row_table_alias,
  )
  let select_star = star_select(
    FromSelect(select=wrapped, alias_=row_table_alias),
  )
  final_select.from = Some(
    FromSelect(select=select_star, alias_=output_table_alias),
  )
  final_select
}

///|
/// variables 付き (sql/helpers.rs::select_rowset_with_variables、rows のみ)
fn select_rowset_with_variables(
  output_pair : (TableAlias, ColumnAlias),
  row_pair : (TableAlias, ColumnAlias),
  variables_pair : (SqlFrom, TableReference),
  output_agg_table_alias : TableAlias,
  row_select : Select,
) -> Select {
  let (output_table_alias, output_column_alias) = output_pair
  let (row_table_alias, row_column_alias) = row_pair
  let (variables_from, variables_table_reference) = variables_pair
  let row = [
    (
      output_column_alias,
      Expression::RowToJson(AliasedTable(output_table_alias)),
    ),
  ]
  let final_select = simple_select(row)
  let wrapped = select_rows_as_json(
    row_select, row_column_alias, row_table_alias,
  )
  let select_star = star_select(
    FromSelect(select=wrapped, alias_=row_table_alias),
  )
  final_select.from = Some(variables_from)
  final_select.joins = [
    CrossJoinLateral(select=select_star, alias_=output_table_alias),
  ]
  final_select.order_by = [
    {
      target: Expression::ColumnReference(
        AliasedColumn(
          table=variables_table_reference,
          column=ColumnAlias(variable_order_field),
        ),
      ),
      direction: Asc,
    },
  ]
  let output_agg_row = [
    (
      output_column_alias,
      wrap_in_json_agg(
        Expression::ColumnReference(
          AliasedColumn(
            table=AliasedTable(output_agg_table_alias),
            column=output_column_alias,
          ),
        ),
      ),
    ),
  ]
  let outer = simple_select(output_agg_row)
  outer.from = Some(
    FromSelect(select=final_select, alias_=output_agg_table_alias),
  )
  outer
}

///|
/// variables テーブルの From (jsonb_to_recordset)
fn from_variables(alias_ : TableAlias) -> SqlFrom {
  FromJsonbToRecordset(
    expression=Value(VVariable(variables_object_placeholder)),
    alias_~,
    columns=[
      (ColumnAlias(variable_order_field), "int4"),
      (ColumnAlias(variables_field), "jsonb"),
    ],
  )
}

// --- sorting (sorting.rs の移植: カラム対象のみ。集約対象は未対応) ---

///|
priv struct OrderByGroupColumn {
  index : Int
  direction : OrderByDirection
  name : String
}

///|
/// 同じ path を持つ order by 要素のグループ (upstream OrderByElementGroup::Columns)
priv struct OrderByGroup {
  path : Array[NdcPathElement]
  columns : Array[OrderByGroupColumn]
}

///|
fn order_direction(s : String) -> OrderByDirection {
  match s {
    "asc" => Asc
    _ => Desc
  }
}

// path のグループ化キー (構造が同じ path だけが JOIN を共有できるよう、
// リレーション名・引数・predicate まで含めて直列化する)

///|
fn ndc_argument_key(a : NdcArgument) -> String {
  match a {
    ALiteral(j) => "lit:\{j.stringify()}"
    AVariable(v) => "var:\{v}"
  }
}

///|
fn ndc_arguments_key(args : Map[String, NdcArgument]) -> String {
  let parts : Array[String] = []
  for k, v in args {
    parts.push("\{k}=\{ndc_argument_key(v)}")
  }
  parts.join(",")
}

///|
fn ndc_target_key(t : NdcComparisonTarget) -> String {
  "\{t.name}/\{t.path.map(p => ndc_path_element_key(p)).join(";")}"
}

///|
fn ndc_value_key(v : NdcComparisonValue) -> String {
  match v {
    CVColumn(name~, path~, scope~) => {
      let scope_key = match scope {
        Some(n) => n.to_string()
        None => ""
      }
      "col(\{name}/\{path.map(p => ndc_path_element_key(p)).join(";")}/\{scope_key})"
    }
    CVScalar(j) => "scalar(\{j.stringify()})"
    CVVariable(name) => "variable(\{name})"
  }
}

///|
fn ndc_expression_key(e : NdcExpression) -> String {
  match e {
    EAnd(xs) => "and(\{xs.map(x => ndc_expression_key(x)).join(",")})"
    EOr(xs) => "or(\{xs.map(x => ndc_expression_key(x)).join(",")})"
    ENot(x) => "not(\{ndc_expression_key(x)})"
    EBinary(column~, operator~, value~) =>
      "bin(\{ndc_target_key(column)} \{operator} \{ndc_value_key(value)})"
    EUnaryIsNull(column~) => "isnull(\{ndc_target_key(column)})"
    EExistsRelated(relationship~, arguments~, predicate~) =>
      "exists_rel(\{relationship},\{ndc_arguments_key(arguments)},\{ndc_predicate_key(predicate)})"
    EExistsUnrelated(collection~, arguments~, predicate~) =>
      "exists_unrel(\{collection},\{ndc_arguments_key(arguments)},\{ndc_predicate_key(predicate)})"
  }
}

///|
fn ndc_predicate_key(p : NdcExpression?) -> String {
  match p {
    None => ""
    Some(e) => ndc_expression_key(e)
  }
}

///|
fn ndc_path_element_key(p : NdcPathElement) -> String {
  "\{p.relationship}(\{ndc_arguments_key(p.arguments)})[\{ndc_predicate_key(p.predicate)}]"
}

///|
/// path が同じ要素をグループ化する (出現順を保持。upstream group_elements)
fn group_order_by_elements(
  elements : Array[NdcOrderByElement],
) -> Array[OrderByGroup] {
  let groups : Map[String, OrderByGroup] = Map([])
  for i, e in elements {
    let key = e.target_path.map(p => ndc_path_element_key(p)).join("|")
    let column : OrderByGroupColumn = {
      index: i,
      direction: order_direction(e.order_direction),
      name: e.target_name,
    }
    match groups.get(key) {
      Some(g) => g.columns.push(column)
      None => groups[key] = { path: e.target_path, columns: [column] }
    }
  }
  groups.values().collect()
}

///|
/// order by 全体を (要素列, 追加 JOIN 列) へ変換する (upstream sorting::translate)。
/// path 無しの要素は現在のテーブルのカラム参照、path 有りの要素は
/// LEFT OUTER JOIN LATERAL 連鎖で対象テーブルのカラムを引き寄せて参照する
fn sorting_translate(
  env : Env,
  state : State,
  scope : TableScope,
  elements : Array[NdcOrderByElement],
) -> (Array[OrderByElement], Array[Join]) raise TranslateError {
  let joins : Array[Join] = []
  let indexed : Array[(Int, OrderByElement)] = []
  for g in group_order_by_elements(elements) {
    if g.path.is_empty() {
      for c in g.columns {
        let column_info = env.lookup_column(scope.current.collection, c.name)
        indexed.push(
          (
            c.index,
            {
              target: Expression::ColumnReference(
                AliasedColumn(
                  table=scope.current.reference,
                  column=ColumnAlias(column_info.name),
                ),
              ),
              direction: c.direction,
            },
          ),
        )
      }
    } else {
      translate_order_by_path_group(env, state, scope, g, indexed, joins)
    }
  }
  // グループ化で崩れた順序を order by リスト上の位置で並べ直す
  indexed.sort_by((a, b) => a.0.compare(b.0))
  (indexed.map(p => p.1), joins)
}

///|
/// リレーション経路を辿る order by グループを変換する
/// (upstream build_select_and_joins_for_order_by_group +
///  process_path_element_for_order_by_targets)
fn translate_order_by_path_group(
  env : Env,
  state : State,
  scope : TableScope,
  group : OrderByGroup,
  indexed : Array[(Int, OrderByElement)],
  joins : Array[Join],
) -> Unit raise TranslateError {
  // 経路の各要素を LEFT OUTER JOIN LATERAL にする。
  // 中間テーブルは次の join に必要なキー列のみを、最後のテーブルは
  // order by 対象カラムを選択する
  let local_joins : Array[(Select, TableAlias)] = []
  let mut last_table = scope.current
  let final_exprs : Array[(Int, OrderByDirection, ColumnAlias)] = []
  for pe_idx in 0..<group.path.length() {
    let pe = group.path[pe_idx]
    let relationship = env.lookup_relationship(pe.relationship)
    let target_alias = state.make_table_alias(
      "ORDER_PART_\{relationship.target_collection}",
    )
    let (table, from_clause) = make_reference_and_from_clause(
      env,
      state,
      MakeFromCollection(relationship.target_collection),
      Some(target_alias),
    )
    let select_list : Array[(ColumnAlias, Expression)] = []
    if pe_idx + 1 < group.path.length() {
      // 次の経路要素の join キー列 (実カラム名をそのままエイリアスに使う)
      let next_rel = env.lookup_relationship(
        group.path[pe_idx + 1].relationship,
      )
      for pair in next_rel.column_mapping {
        let (source_col, _) = pair
        let col = env.lookup_column(table.collection, source_col)
        select_list.push(
          (
            ColumnAlias(col.name),
            Expression::ColumnReference(
              AliasedColumn(table=table.reference, column=ColumnAlias(col.name)),
            ),
          ),
        )
      }
    } else {
      // 配列リレーション越しのカラムソートは行数が定まらないため不可
      // (upstream MissingAggregateForArrayRelationOrdering)
      if relationship.relationship_type == "array" {
        raise NotImplemented(
          "order by column across an array relationship (requires an aggregate)",
        )
      }
      for c in group.columns {
        let col = env.lookup_column(relationship.target_collection, c.name)
        select_list.push(
          (
            ColumnAlias(col.name),
            Expression::ColumnReference(
              AliasedColumn(table=table.reference, column=ColumnAlias(col.name)),
            ),
          ),
        )
        final_exprs.push((c.index, c.direction, ColumnAlias(col.name)))
      }
    }
    // この経路要素の select: join 条件 (+ predicate) 付き
    let select = simple_select(select_list)
    select.from = Some(from_clause)
    let join_condition = translate_column_mapping(
      env,
      last_table,
      table.reference,
      true_expr(),
      relationship,
    )
    select.where_ = match pe.predicate {
      None => join_condition
      Some(p) =>
        And(
          left=join_condition,
          right=filtering_translate(env, state, TableScope::new(table), p),
        )
    }
    local_joins.push((select, target_alias))
    last_table = table
  }
  // 経路全体を包む select: 最後のテーブルから対象カラムを選択し、
  // 先頭の join を FROM に、残りを JOIN に並べる
  let wrapping = simple_select(
    final_exprs.map(e => {
      (
        e.2,
        Expression::ColumnReference(
          AliasedColumn(table=last_table.reference, column=e.2),
        ),
      )
    }),
  )
  let (first_select, first_alias) = local_joins[0]
  wrapping.from = Some(FromSelect(select=first_select, alias_=first_alias))
  for i in 1..<local_joins.length() {
    let (s, a) = local_joins[i]
    wrapping.joins.push(LeftOuterJoinLateral(select=s, alias_=a))
  }
  let order_alias = state.make_table_alias(
    "ORDER_FOR_\{scope.current.collection}",
  )
  joins.push(LeftOuterJoinLateral(select=wrapping, alias_=order_alias))
  for e in final_exprs {
    indexed.push(
      (
        e.0,
        {
          target: Expression::ColumnReference(
            AliasedColumn(table=AliasedTable(order_alias), column=e.2),
          ),
          direction: e.1,
        },
      ),
    )
  }
}

// --- filtering ---

///|
fn filtering_translate(
  env : Env,
  state : State,
  scope : TableScope,
  predicate : NdcExpression,
) -> Expression raise TranslateError {
  let (filter_expression, joins) = translate_expression_with_joins(
    env, state, scope, predicate,
  )
  if joins.is_empty() {
    filter_expression
  } else {
    let first = joins[0]
    let rest : Array[Join] = []
    for i in 1..<joins.length() {
      rest.push(joins[i])
    }
    let (select, alias_) = match first {
      LeftOuterJoinLateral(select~, alias_~)
      | InnerJoinLateral(select~, alias_~)
      | FullOuterJoinLateral(select~, alias_~)
      | CrossJoinLateral(select~, alias_~)
      | CrossJoin(select~, alias_~) => (select, alias_)
    }
    where_exists_select(FromSelect(select~, alias_~), rest, filter_expression)
  }
}

///|
fn get_comparison_target_type(
  env : Env,
  scope : TableScope,
  column : NdcComparisonTarget,
) -> String raise TranslateError {
  let info = env.lookup_column(scope.current.collection, column.name)
  match info.ty {
    TScalar(s) => s
    _ => raise NotImplemented("non-scalar type in operator")
  }
}

///|
fn translate_comparison_target(
  env : Env,
  scope : TableScope,
  column : NdcComparisonTarget,
) -> Expression raise TranslateError {
  let info = env.lookup_column(scope.current.collection, column.name)
  Expression::ColumnReference(
    TableColumn(table=scope.current.reference, name=ColumnName(info.name)),
  )
}

///|
fn make_unnest_subquery(state : State, expression : Expression) -> Expression {
  let subquery_alias = state.make_table_alias("in_subquery")
  let subquery_reference = AliasedTable(subquery_alias)
  let subquery_from = FromUnnest(expression~, alias_=subquery_alias, columns=[
    ColumnAlias("value"),
  ])
  let subquery = simple_select([
    (
      ColumnAlias("value"),
      Expression::ColumnReference(
        TableColumn(table=subquery_reference, name=ColumnName("value")),
      ),
    ),
  ])
  subquery.from = Some(subquery_from)
  CorrelatedSubSelect(subquery)
}

///|
fn translate_comparison_pathelements(
  env : Env,
  state : State,
  current_table : CurrentTable,
  path : Array[NdcPathElement],
) -> (CurrentTable, Array[Join]) raise TranslateError {
  let joins : Array[Join] = []
  let mut table = current_table
  for path_element in path {
    let relationship = env.lookup_relationship(path_element.relationship)
    let target_table_alias = state.make_boolean_expression_table_alias(
      relationship.target_collection,
    )
    let (new_table, from_clause) = make_reference_and_from_clause(
      env,
      state,
      MakeFromCollection(relationship.target_collection),
      Some(target_table_alias),
    )
    let select = simple_select([])
    select.from = Some(from_clause)
    select.select_list = SelectStar
    let new_scope = TableScope::new(new_table)
    let (rel_cond, rel_joins) = match path_element.predicate {
      None => (true_expr(), [])
      Some(predicate) =>
        translate_expression_with_joins(env, state, new_scope, predicate)
    }
    let cond = translate_column_mapping(
      env,
      table,
      new_table.reference,
      rel_cond,
      relationship,
    )
    select.where_ = cond
    select.joins = rel_joins
    joins.push(InnerJoinLateral(select~, alias_=target_table_alias))
    table = new_table
  }
  if joins.is_empty() {
    (table, [])
  } else {
    let outer_select = simple_select([])
    outer_select.select_list = SelectStarFrom(table.reference)
    let first = joins[0]
    let rest : Array[Join] = []
    for i in 1..<joins.length() {
      rest.push(joins[i])
    }
    let (select, alias_) = match first {
      LeftOuterJoinLateral(select~, alias_~)
      | InnerJoinLateral(select~, alias_~)
      | FullOuterJoinLateral(select~, alias_~)
      | CrossJoinLateral(select~, alias_~)
      | CrossJoin(select~, alias_~) => (select, alias_)
    }
    outer_select.from = Some(FromSelect(select~, alias_~))
    outer_select.joins = rest
    let new_alias = state.make_boolean_expression_table_alias(table.collection)
    (
      { collection: table.collection, reference: AliasedTable(new_alias) },
      [FullOuterJoinLateral(select=outer_select, alias_=new_alias)],
    )
  }
}

///|
fn translate_comparison_value(
  env : Env,
  state : State,
  scope : TableScope,
  value : NdcComparisonValue,
  ty : PgType,
) -> (Expression, Array[Join]) raise TranslateError {
  match value {
    CVColumn(name~, path~, scope=scope_idx) => {
      let scoped = scope.scoped_table(scope_idx)
      let (table_ref, joins) = translate_comparison_pathelements(
        env, state, scoped, path,
      )
      let info = env.lookup_column(table_ref.collection, name)
      (
        Expression::ColumnReference(
          TableColumn(table=table_ref.reference, name=ColumnName(info.name)),
        ),
        joins,
      )
    }
    CVScalar(json_value) => (values_translate(env, state, json_value, ty), [])
    CVVariable(name) =>
      (variables_translate(env, state, env.get_variables_table(), name, ty), [])
  }
}

///|
fn translate_expression_with_joins(
  env : Env,
  state : State,
  scope : TableScope,
  predicate : NdcExpression,
) -> (Expression, Array[Join]) raise TranslateError {
  match predicate {
    EAnd(expressions) => {
      let acc_joins : Array[Join] = []
      let and_expressions : Array[Expression] = []
      for expr in expressions {
        let (translated, expr_joins) = translate_expression_with_joins(
          env, state, scope, expr,
        )
        acc_joins.append(expr_joins)
        and_expressions.push(translated)
      }
      (fold_and_balanced(and_expressions), acc_joins)
    }
    EOr(expressions) => {
      let expressions = optimize_or_to_in(env, scope, expressions)
      let acc_joins : Array[Join] = []
      let or_expressions : Array[Expression] = []
      for expr in expressions {
        let (translated, expr_joins) = translate_expression_with_joins(
          env, state, scope, expr,
        )
        acc_joins.append(expr_joins)
        or_expressions.push(translated)
      }
      (fold_or_balanced(or_expressions), acc_joins)
    }
    ENot(expression) => {
      let (expr, joins) = translate_expression_with_joins(
        env, state, scope, expression,
      )
      (Not(expr), joins)
    }
    EUnaryIsNull(column~) => {
      let value = translate_comparison_target(env, scope, column)
      (UnaryOperation(expression=value, operator="IS NULL"), [])
    }
    EBinary(column~, operator~, value~) => {
      let left_typ = get_comparison_target_type(env, scope, column)
      let op = env.lookup_comparison_operator(left_typ, operator)
      if op.operator_kind == "in" {
        let joins : Array[Join] = []
        let left = translate_comparison_target(env, scope, column)
        match value {
          CVColumn(_) as v => {
            let (right, right_joins) = translate_comparison_value(
              env,
              state,
              scope,
              v,
              TScalar(left_typ),
            )
            joins.append(right_joins)
            let right = [make_unnest_subquery(state, right)]
            (BinaryArrayOperation(left~, operator="IN", right~), joins)
          }
          CVScalar(json_value) =>
            match json_value {
              Json::Array(values) =>
                if values.is_empty() {
                  (false_expr(), joins)
                } else {
                  let right : Array[Expression] = []
                  for v in values {
                    right.push(
                      values_translate(env, state, v, TScalar(left_typ)),
                    )
                  }
                  (BinaryArrayOperation(left~, operator="IN", right~), joins)
                }
              _ => raise TypeMismatch("_in requires array value")
            }
          CVVariable(_) as v => {
            let array_type = TArray(TScalar(left_typ))
            let (right, right_joins) = translate_comparison_value(
              env, state, scope, v, array_type,
            )
            joins.append(right_joins)
            let right = make_unnest_subquery(state, right)
            (BinaryOperation(left~, operator=op.operator_name, right~), joins)
          }
        }
      } else {
        let joins : Array[Join] = []
        let left = translate_comparison_target(env, scope, column)
        let (right, right_joins) = translate_comparison_value(
          env,
          state,
          scope,
          value,
          TScalar(op.argument_type),
        )
        joins.append(right_joins)
        if op.is_infix {
          (BinaryOperation(left~, operator=op.operator_name, right~), joins)
        } else {
          (FunctionCall(function=op.operator_name, args=[left, right]), joins)
        }
      }
    }
    EExistsRelated(relationship~, arguments~, predicate~) => {
      ignore(arguments)
      match predicate {
        None => (true_expr(), [])
        Some(predicate) => {
          let relationship = env.lookup_relationship(relationship)
          let (table, from_clause) = make_reference_and_from_clause(
            env,
            state,
            MakeFromCollection(relationship.target_collection),
            None,
          )
          let select = simple_select([(ColumnAlias("one"), Value(VInt4(1)))])
          select.from = Some(from_clause)
          let new_scope = scope.new_from_scope(table)
          let (exists_cond, exists_joins) = translate_expression_with_joins(
            env, state, new_scope, predicate,
          )
          let cond = translate_column_mapping(
            env,
            scope.current,
            table.reference,
            exists_cond,
            relationship,
          )
          select.where_ = cond
          select.joins = exists_joins
          (Exists(select~), [])
        }
      }
    }
    EExistsUnrelated(collection~, arguments~, predicate~) => {
      ignore(arguments)
      match predicate {
        None => (true_expr(), [])
        Some(predicate) => {
          let (table, from_clause) = make_reference_and_from_clause(
            env,
            state,
            MakeFromCollection(collection),
            None,
          )
          let select = simple_select([(ColumnAlias("one"), Value(VInt4(1)))])
          select.from = Some(from_clause)
          let new_scope = scope.new_from_scope(table)
          let (expr, expr_joins) = translate_expression_with_joins(
            env, state, new_scope, predicate,
          )
          select.where_ = expr
          select.joins = expr_joins
          (Exists(select~), [])
        }
      }
    }
  }
}

///|
/// OR の等値比較群を IN にまとめる最適化 (filtering.rs::optimize_or_to_in)
fn optimize_or_to_in(
  env : Env,
  scope : TableScope,
  expressions : Array[NdcExpression],
) -> Array[NdcExpression] raise TranslateError {
  if expressions.length() < 2 {
    return expressions
  }
  // 全てが等値比較 (スカラー値・field_path なし) かチェックしつつ、カラム名でグループ化
  // Rust の BTreeMap 同様にカラム名順で出力する
  let group_keys : Array[String] = []
  let groups : Map[String, (Array[NdcComparisonValue], Array[NdcExpression])] = Map([],
  )
  for expr in expressions {
    match expr {
      EBinary(column~, operator~, value~) => {
        let left_typ = get_comparison_target_type(env, scope, column)
        let op = env.lookup_comparison_operator(left_typ, operator)
        if op.operator_kind != "equal" || !column.path.is_empty() {
          return expressions
        }
        match groups.get(column.name) {
          Some((values, exprs)) => {
            values.push(value)
            exprs.push(expr)
          }
          None => {
            group_keys.push(column.name)
            groups[column.name] = ([value], [expr])
          }
        }
      }
      _ => return expressions
    }
  }
  // Rust の BTreeMap と同じ辞書式順 (MoonBit の String 既定比較は長さ優先のため自前実装)
  group_keys.sort_by((a, b) => lex_compare(a, b))
  let out : Array[NdcExpression] = []
  for key in group_keys {
    let (values, original_exprs) = groups.get(key).unwrap()
    let mut all_scalar = true
    let json_values : Array[Json] = []
    for v in values {
      match v {
        CVScalar(j) => json_values.push(j)
        _ => all_scalar = false
      }
    }
    if values.length() >= 2 && all_scalar {
      out.push(
        EBinary(
          column={ name: key, path: [] },
          operator="_in",
          value=CVScalar(Json::array(json_values)),
        ),
      )
    } else {
      out.append(original_exprs)
    }
  }
  out
}

// --- 定数畳み込み (rewrites/constant_folding.rs) ---

///|
fn normalize_select(select : Select) -> Select {
  select.select_list = normalize_select_list(select.select_list)
  select.from = match select.from {
    Some(FromSelect(select~, alias_~)) =>
      Some(FromSelect(select=normalize_select(select), alias_~))
    other => other
  }
  select.joins = select.joins.map(j => normalize_join(j))
  select.where_ = normalize_expr(select.where_)
  select.order_by = select.order_by.map(e => {
    target: normalize_expr(e.target),
    direction: e.direction,
  })
  select
}

///|
fn normalize_select_list(select_list : SelectList) -> SelectList {
  match select_list {
    SelectListComposite(l1, l2) =>
      SelectListComposite(normalize_select_list(l1), normalize_select_list(l2))
    SelectList(items) =>
      SelectList(
        items.map(item => {
          let (a, e) = item
          (a, normalize_expr(e))
        }),
      )
    other => other
  }
}

///|
fn normalize_join(join : Join) -> Join {
  match join {
    LeftOuterJoinLateral(select~, alias_~) =>
      LeftOuterJoinLateral(select=normalize_select(select), alias_~)
    InnerJoinLateral(select~, alias_~) =>
      InnerJoinLateral(select=normalize_select(select), alias_~)
    FullOuterJoinLateral(select~, alias_~) =>
      FullOuterJoinLateral(select=normalize_select(select), alias_~)
    CrossJoinLateral(select~, alias_~) =>
      CrossJoinLateral(select=normalize_select(select), alias_~)
    CrossJoin(select~, alias_~) =>
      CrossJoin(select=normalize_select(select), alias_~)
  }
}

///|
fn normalize_expr(expr : Expression) -> Expression {
  match expr {
    And(left~, right~) => {
      let l = normalize_expr(left)
      let r = normalize_expr(right)
      match (l, r) {
        (Value(VBool(true)), Value(VBool(true))) => Value(VBool(true))
        (Value(VBool(true)), rr) => rr
        (ll, Value(VBool(true))) => ll
        (ll, rr) => And(left=ll, right=rr)
      }
    }
    Or(left~, right~) => {
      let l = normalize_expr(left)
      let r = normalize_expr(right)
      match (l, r) {
        (Value(VBool(false)), Value(VBool(false))) => Value(VBool(false))
        (Value(VBool(false)), rr) => rr
        (ll, Value(VBool(false))) => ll
        (ll, rr) => Or(left=ll, right=rr)
      }
    }
    Exists(select~) => Exists(select=normalize_select(select))
    Not(e) =>
      match normalize_expr(e) {
        Value(VBool(false)) => Value(VBool(true))
        Value(VBool(true)) => Value(VBool(false))
        ne => Not(ne)
      }
    BinaryOperation(left~, operator~, right~) =>
      BinaryOperation(
        left=normalize_expr(left),
        operator~,
        right=normalize_expr(right),
      )
    BinaryArrayOperation(left~, operator~, right~) =>
      BinaryArrayOperation(
        left=normalize_expr(left),
        operator~,
        right=right.map(e => normalize_expr(e)),
      )
    UnaryOperation(expression~, operator~) =>
      UnaryOperation(expression=normalize_expr(expression), operator~)
    FunctionCall(function~, args~) =>
      FunctionCall(function~, args=args.map(e => normalize_expr(e)))
    JsonBuildObject(items) =>
      JsonBuildObject(
        items.map(item => {
          let (k, e) = item
          (k, normalize_expr(e))
        }),
      )
    CorrelatedSubSelect(select) => CorrelatedSubSelect(normalize_select(select))
    other => other
  }
}

// --- エントリポイント ---

///|
/// NDC QueryRequest → SQL (正規化済み)
pub fn translate_query_request(
  metadata : PgMetadata,
  request : QueryRequest,
) -> SQL raise TranslateError {
  let state : State = { global_table_index: 0 }
  let variables_pair : (SqlFrom, TableReference)? = match request.variables {
    Some(_) => {
      let alias_ = state.make_table_alias("%variables_table")
      Some((from_variables(alias_), AliasedTable(alias_)))
    }
    None => None
  }
  let env : Env = {
    metadata,
    relationships: request.collection_relationships,
    variables_table: match variables_pair {
      Some((_, r)) => Some(r)
      None => None
    },
  }
  let row_select = translate_query(
    env,
    state,
    MakeFromCollection(request.collection),
    None,
    request.query,
  )
  // upstream (query/mod.rs) と同じ順で採番する:
  // universe → rows → aggregates → universe_agg
  let output = (state.make_table_alias("universe"), ColumnAlias("universe"))
  let row = (state.make_table_alias("rows"), ColumnAlias("rows"))
  let _aggregates = state.make_table_alias("aggregates")
  let universe_agg = state.make_table_alias("universe_agg")
  let json_select = match variables_pair {
    None => select_rowset_without_variables(true, output, row, row_select)
    Some(vp) =>
      select_rowset_with_variables(output, row, vp, universe_agg, row_select)
  }
  let json_select = normalize_select(json_select)
  let sql = SQL::new()
  json_select.to_sql(sql)
  sql
}

///|
/// UTF-16 コード単位の辞書式比較 (Rust の str 比較相当)
fn lex_compare(a : String, b : String) -> Int {
  let ac = a.iter().collect()
  let bc = b.iter().collect()
  let n = if ac.length() < bc.length() { ac.length() } else { bc.length() }
  for i in 0..<n {
    if ac[i] != bc[i] {
      return ac[i].to_int() - bc[i].to_int()
    }
  }
  a.length() - b.length()
}
