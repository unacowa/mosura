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
/// ロール別のモデル権限 (M5)
pub(all) struct ModelPermission {
  role : String
  /// 行フィルタ (where 相当の JSON。null なら全行可)
  filter : Json?
  allow_subscriptions : Bool
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
