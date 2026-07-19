// lang-graphql/src/ast/executable.rs の移植

///|
/// 実行可能な GraphQL ドキュメント
pub(all) struct ExecutableDocument {
  items : Array[Spanning[ExecutableDefinition]]
}

///|
pub(all) enum ExecutableDefinition {
  Operation(OperationDefinition)
  Fragment(FragmentDefinition)
}

///|
/// フィールド/ディレクティブの引数
pub type Argument = Spanning[KeyValue[Value]]

///|
/// ディレクティブ。例: `@deprecated(reason: "...")`
pub(all) struct Directive {
  name : Spanning[Name]
  arguments : Spanning[Array[Argument]]?
}

///|
/// オペレーション定義
pub(all) struct OperationDefinition {
  ty : OperationType
  name : Spanning[Name]?
  variable_definitions : Spanning[Array[Spanning[VariableDefinition]]]?
  directives : Array[Spanning[Directive]]
  selection_set : Spanning[SelectionSet]
}

///|
/// 変数定義。例: `$name: String!`
pub(all) struct VariableDefinition {
  name : Spanning[Name]
  var_type : Spanning[GType]
  default_value : Spanning[ConstValue]?
}

///|
/// セレクションセット。例: `{ name age }`
pub(all) struct SelectionSet {
  items : Array[Spanning[Selection]]
}

///|
pub(all) enum Selection {
  Field(Field)
  FragmentSpread(FragmentSpread)
  InlineFragment(InlineFragment)
}

///|
/// フィールド選択
pub(all) struct Field {
  field_alias : Spanning[Alias]?
  name : Spanning[Name]
  arguments : Spanning[Array[Argument]]?
  directives : Array[Spanning[Directive]]
  selection_set : Spanning[SelectionSet]?
}

///|
/// フラグメントスプレッド。例: `... userFields`
pub(all) struct FragmentSpread {
  fragment_name : Spanning[Name]
  directives : Array[Spanning[Directive]]
}

///|
/// インラインフラグメント。例: `... on User { name }`
pub(all) struct InlineFragment {
  type_condition : Spanning[TypeCondition]?
  directives : Array[Spanning[Directive]]
  selection_set : Spanning[SelectionSet]
}

///|
/// フラグメント定義
pub(all) struct FragmentDefinition {
  name : Spanning[Name]
  type_condition : Spanning[TypeCondition]
  directives : Array[Spanning[Directive]]
  selection_set : Spanning[SelectionSet]
}

///|
/// 型条件 (`on` に続く型)
pub(all) struct TypeCondition {
  on : Spanning[TypeName]
}
