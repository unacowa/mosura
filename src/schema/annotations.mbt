// スキーマノードに付与するアノテーション。
// V3 の SchemaContext (GenericNodeInfo / NamespacedNodeInfo) を具象型にしたもの。
// normalized AST 経由で IR 生成が参照する「このフィールドは何にマップされるか」の情報。

///|
pub(all) enum Annotation {
  /// introspection 用フィールド等、追加情報なし
  NoAnnotation
  /// query_root 上のモデル選択フィールド (例: articles)
  ModelSelect(String)
  /// query_root 上の主キー選択フィールド (例: articles_by_pk)
  ModelSelectByPk(String)
  /// オブジェクト型上の DB カラムフィールド (モデルのフィールド)
  ModelField(String)
  /// オブジェクト型上のリレーションシップフィールド (Relationship 名)
  RelationshipField(String)
  /// 入力引数: where / order_by / limit / offset / pk 等
  InputArg(InputArgKind)
  /// __typename 等の introspection フィールド
  Introspection
  /// mutation_root: insert_<model>
  ModelInsert(String)
  /// mutation_root: update_<model>_by_pk
  ModelUpdateByPk(String)
  /// mutation_root: delete_<model>_by_pk
  ModelDeleteByPk(String)
  /// mutation_response.affected_rows
  AffectedRows
  /// mutation_response.returning
  ReturningRows(String)
} derive(Eq)

///|
pub(all) enum InputArgKind {
  ArgWhere
  ArgOrderBy
  ArgLimit
  ArgOffset
  ArgPkColumn(String)
  /// boolean expression / order_by 入力オブジェクトのフィールド (カラム名)
  BoolExpField(String)
  /// _and / _or / _not
  BoolExpLogical(String)
  /// 比較演算子 (_eq, _gt, ...)
  BoolExpOperator(String)
  /// bool_exp 入力のリレーションフィールド (Relationship 名。exists に変換される)
  BoolExpRelationship(String)
  /// order_by 入力のカラム
  OrderByField(String)
  /// order_by 入力のリレーションフィールド (Relationship 名。オブジェクトリレーションのみ)
  OrderByRelationship(String)
  /// enum 値 (Asc / Desc 等)
  EnumValue(String)
  /// M6: insert/update 入力オブジェクトのフィールド
  MutationInputField(String)
} derive(Eq)

///|
/// ロール別に付与される情報 (M5 で行フィルタ等を持たせる)
pub(all) enum NamespacedInfo {
  NoInfo
  /// M5: ロール別のモデル選択権限 (行フィルタは metadata 側を参照するためモデル名のみ)
  ModelPermission(String)
} derive(Eq)

///|
/// Namespaced ノード解決のコンテキスト。
/// AllowAll = 全ロール許可 (admin / テスト用)、Role = 指定ロールで条件付き解決
pub(all) enum NamespaceCtx {
  AllowAll
  Role(String)
}

///|
/// V3 の NamespacedData
pub(all) enum NamespacedData {
  NDAllowAll
  Conditional(Map[String, NamespacedInfo])
} derive(Eq)

///|
/// V3 の Namespaced<S, C>
pub(all) struct Namespaced[C] {
  namespaced : NamespacedData
  data : C
}

///|
pub fn[C] allow_all_namespaced(data : C) -> Namespaced[C] {
  { namespaced: NDAllowAll, data }
}

///|
pub fn[C] conditional_namespaced(
  data : C,
  map : Map[String, NamespacedInfo],
) -> Namespaced[C] {
  { namespaced: Conditional(map), data }
}

///|
/// NamespacedGetter (V3 の trait を関数に)
pub fn[C] NamespaceCtx::get(
  self : NamespaceCtx,
  namespaced : Namespaced[C],
) -> (C, NamespacedInfo)? {
  match (self, namespaced.namespaced) {
    (AllowAll, _) => Some((namespaced.data, NoInfo))
    (Role(_), NDAllowAll) => Some((namespaced.data, NoInfo))
    (Role(r), Conditional(map)) =>
      match map.get(r) {
        Some(info) => Some((namespaced.data, info))
        None => None
      }
  }
}

///|
/// normalized AST のノード情報 (V3 の NodeInfo)
pub(all) struct NodeInfo {
  generic : Annotation
  namespaced : NamespacedInfo
} derive(Eq)
