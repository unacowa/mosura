// Mosura メタデータの型定義 (OpenDD の語彙を踏襲したサブセット)
// YAML (マルチドキュメント) の各ドキュメントは kind/version/definition を持つ

///|
pub suberror MetadataError {
  MetadataParse(String)
  UnknownKind(String)
  MissingField(kind~ : String, field~ : String)
  InvalidValue(kind~ : String, field~ : String, message~ : String)
  DuplicateName(kind~ : String, name~ : String)
  UnknownReference(kind~ : String, name~ : String, referenced_from~ : String)
} derive(Debug)

///|
pub fn MetadataError::display(self : MetadataError) -> String {
  match self {
    MetadataParse(m) => "failed to parse metadata: \{m}"
    UnknownKind(k) => "unknown metadata kind: \{k}"
    MissingField(kind~, field~) =>
      "missing field '\{field}' in \{kind} definition"
    InvalidValue(kind~, field~, message~) =>
      "invalid value for '\{field}' in \{kind}: \{message}"
    DuplicateName(kind~, name~) => "duplicate \{kind} name: \{name}"
    UnknownReference(kind~, name~, referenced_from~) =>
      "unknown \{kind} '\{name}' referenced from \{referenced_from}"
  }
}

///|
/// 接続先 (PostgreSQL) の定義
pub(all) struct DataConnectorLink {
  name : String
  /// 接続文字列そのもの、または環境変数名のどちらか
  url : String?
  url_from_env : String?
  /// テーブルの既定スキーマ (省略時 "public")
  db_schema : String
}

///|
/// オブジェクト型のフィールド
pub(all) struct ObjectTypeField {
  name : String
  /// GraphQL 型表記 (例: "Int!", "String", "[Int!]")
  field_type : @graphql.GType
  /// DB カラム名 (省略時はフィールド名と同じ)
  column : String
  description : String?
}

///|
/// オブジェクト型
pub(all) struct ObjectTypeDef {
  name : String
  /// GraphQL 上の型名 (省略時は name)
  graphql_type_name : String
  fields : Array[ObjectTypeField]
  description : String?
}

///|
/// モデル (公開されるコレクション)
pub(all) struct Model {
  name : String
  object_type : String
  /// 接続先
  connector : String
  /// テーブル名
  collection : String
  /// where で使えるフィールド
  filterable_fields : Array[String]
  /// order_by で使えるフィールド
  orderable_fields : Array[String]
  /// 主キーフィールド (<name>_by_pk / update/delete_by_pk の生成に使う)
  primary_key : Array[String]
  /// 一覧取得のルートフィールド名 (省略時はモデル名)
  select_many_name : String
  /// 一意取得のルートフィールド群 (フィールド名, キー列)。
  /// 空の場合は primary_key から <select_many_name>_by_pk を生成
  select_uniques : Array[(String, Array[String])]
  description : String?
}

///|
/// リレーションシップ
pub(all) enum RelationshipKind {
  RelObject
  RelArray
}

///|
pub(all) struct Relationship {
  name : String
  /// リレーション元のオブジェクト型
  source_type : String
  /// リレーション先のモデル
  target_model : String
  /// フィールドマッピング (source field → target field)
  mapping : Array[(String, String)]
  kind : RelationshipKind
  description : String?
}

///|
/// カラムプリセット (insert/update 時に値を固定するカラム)。
/// value は {sessionVariable: "x-hasura-*"} または {literal: ...}
pub(all) struct FieldPreset {
  field : String
  value : Json
}

///|
/// ロール別の insert 権限
pub(all) struct InsertPermission {
  /// 入力を許可するカラム (None = 全カラム)。presets のカラムは常に入力不可
  columns : Array[String]?
  presets : Array[FieldPreset]
  /// post-write CHECK: 挿入後の行が満たすべき述語 (filter と同じ JSON 形式)。
  /// 満たさない行が 1 行でもあればミューテーション全体を拒否しロールバックする
  check : Json?
}

///|
/// 「presets のカラムは常に入力不可、columns 制限があれば membership を要求」
/// の共通判定 (schemagen の入力型可視性と ir の防御的検査の単一の真実)
fn permission_allows_column(
  columns : Array[String]?,
  presets : Array[FieldPreset],
  field_name : String,
) -> Bool {
  for preset in presets {
    if preset.field == field_name {
      return false
    }
  }
  match columns {
    None => true
    Some(cols) => cols.contains(field_name)
  }
}

///|
/// このロールが insert 入力でカラムを設定できるか
pub fn InsertPermission::allows_column(
  self : InsertPermission,
  field_name : String,
) -> Bool {
  permission_allows_column(self.columns, self.presets, field_name)
}

///|
/// ロール別の update 権限
pub(all) struct UpdatePermission {
  /// _set を許可するカラム (None = 全カラム)。presets のカラムは常に入力不可
  columns : Array[String]?
  /// 更新対象行の行フィルタ (WHERE に AND される。None なら全行可)。
  /// filter は更新「前」の行に、check は更新「後」の行に適用される
  filter : Json?
  presets : Array[FieldPreset]
  /// post-write CHECK: 更新後の行が満たすべき述語 (filter と同じ JSON 形式)。
  /// 満たさなければミューテーション全体を拒否しロールバックする
  check : Json?
}

///|
/// このロールが _set 入力でカラムを設定できるか
pub fn UpdatePermission::allows_column(
  self : UpdatePermission,
  field_name : String,
) -> Bool {
  permission_allows_column(self.columns, self.presets, field_name)
}

///|
/// ロール別の delete 権限
pub(all) struct DeletePermission {
  /// 削除対象行の行フィルタ (WHERE に AND される。None なら全行可)
  filter : Json?
}

///|
/// ロール別のモデル権限 (M5/M6)
pub(all) struct ModelPermission {
  role : String
  /// select の行フィルタ (where 相当の JSON。null なら全行可)
  filter : Json?
  allow_subscriptions : Bool
  /// M6: ミューテーション権限 (None = そのロールには生成しない)
  insert : InsertPermission?
  update : UpdatePermission?
  delete : DeletePermission?
}

///|
pub(all) struct ModelPermissions {
  model_name : String
  permissions : Array[ModelPermission]
}

///|
/// ロール別の型 (カラム) 権限 (M5)
pub(all) struct TypePermission {
  role : String
  allowed_fields : Array[String]
}

///|
pub(all) struct TypePermissions {
  type_name : String
  permissions : Array[TypePermission]
}

///|
/// 認証設定 (M5)
pub(all) struct AuthConfig {
  /// 開発モード: x-hasura-admin-secret 一致で任意ロール
  admin_secret : String?
  /// JWT HS256 シークレット (M5)
  jwt_hs256_secret : String?
  jwt_hs256_secret_from_env : String?
}

///|
/// 解決済みメタデータ
pub(all) struct Metadata {
  connectors : Map[String, DataConnectorLink]
  object_types : Map[String, ObjectTypeDef]
  models : Map[String, Model]
  /// source_type 名 → その型のリレーション一覧
  relationships : Map[String, Array[Relationship]]
  model_permissions : Map[String, ModelPermissions]
  type_permissions : Map[String, TypePermissions]
  auth : AuthConfig?
}
