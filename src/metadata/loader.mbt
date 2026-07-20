// YAML / JSON メタデータのロード。
// - マルチドキュメント YAML (--- 区切り)
// - マージキー (<<:) の展開 (yaml ライブラリが未対応のため Json 後処理で行う)

///|
fn json_get(j : Json, key : String) -> Json? {
  match j {
    Json::Object(m) => m.get(key)
    _ => None
  }
}

///|
fn json_string_field(
  j : Json,
  kind : String,
  key : String,
) -> String raise MetadataError {
  match json_get(j, key) {
    Some(Json::String(s)) => s
    Some(_) => raise InvalidValue(kind~, field=key, message="must be a string")
    None => raise MissingField(kind~, field=key)
  }
}

///|
fn json_opt_string_field(
  j : Json,
  kind : String,
  key : String,
) -> String? raise MetadataError {
  match json_get(j, key) {
    Some(Json::String(s)) => Some(s)
    Some(Json::Null) | None => None
    Some(_) => raise InvalidValue(kind~, field=key, message="must be a string")
  }
}

///|
fn json_string_array_field(
  j : Json,
  kind : String,
  key : String,
) -> Array[String] raise MetadataError {
  match json_get(j, key) {
    Some(Json::Array(items)) => {
      let out = []
      for item in items {
        match item {
          Json::String(s) => out.push(s)
          _ =>
            raise InvalidValue(
              kind~,
              field=key,
              message="must be an array of strings",
            )
        }
      }
      out
    }
    Some(Json::Null) | None => []
    Some(_) => raise InvalidValue(kind~, field=key, message="must be an array")
  }
}

///|
/// ミューテーション権限セクションの columns (省略時 None = 全カラム)
fn parse_permission_columns(sec : Json) -> Array[String]? {
  match json_get(sec, "columns") {
    Some(Json::Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          Json::String(s) => out.push(s)
          _ => ()
        }
      }
      Some(out)
    }
    _ => None
  }
}

///|
/// ミューテーション権限セクションの presets
fn parse_permission_presets(
  sec : Json,
  kind : String,
) -> Array[FieldPreset] raise MetadataError {
  let out : Array[FieldPreset] = []
  match json_get(sec, "presets") {
    Some(Json::Array(items)) =>
      for item in items {
        let field = json_string_field(item, kind, "field")
        let value = match json_get(item, "value") {
          Some(v) => v
          None => raise MissingField(kind~, field="presets[].value")
        }
        out.push({ field, value })
      }
    _ => ()
  }
  out
}

///|
/// マージキー `<<` を展開する (マップ直下の << の中身を親へ取り込む。自身のキーが優先)
pub fn expand_merge_keys(j : Json) -> Json {
  match j {
    Json::Object(m) => {
      let out : Map[String, Json] = Map([])
      match m.get("<<") {
        Some(Json::Object(base)) =>
          for k, v in base {
            out[k] = expand_merge_keys(v)
          }
        _ => ()
      }
      for k, v in m {
        if k != "<<" {
          out[k] = expand_merge_keys(v)
        }
      }
      Json::object(out)
    }
    Json::Array(items) => Json::array(items.map(i => expand_merge_keys(i)))
    other => other
  }
}

///|
/// GraphQL 型表記 ("Int!" 等) をパース
fn parse_gql_type(
  text : String,
  kind : String,
  field : String,
) -> @graphql.GType raise MetadataError {
  let parser = @graphql.Parser::new(@utf8.encode(text))
  let t = parser.parse_type() catch {
    @graphql.ParseErr(_) =>
      raise InvalidValue(kind~, field~, message="invalid GraphQL type: \{text}")
  }
  t.item
}

///|
/// 1 ドキュメント (kind/version/definition) を Metadata に取り込む
fn load_document(
  meta : MetadataBuilder,
  doc : Json,
) -> Unit raise MetadataError {
  let doc = expand_merge_keys(doc)
  let kind = json_string_field(doc, "document", "kind")
  let def = match json_get(doc, "definition") {
    Some(d) => d
    None => raise MissingField(kind~, field="definition")
  }
  match kind {
    "DataConnectorLink" => {
      let name = json_string_field(def, kind, "name")
      let connection = match json_get(def, "connection") {
        Some(c) => c
        None => raise MissingField(kind~, field="connection")
      }
      let link : DataConnectorLink = {
        name,
        url: json_opt_string_field(connection, kind, "url"),
        url_from_env: json_opt_string_field(connection, kind, "urlFromEnv"),
        db_schema: match json_opt_string_field(def, kind, "schema") {
          Some(s) => s
          None => "public"
        },
      }
      if meta.connectors.contains(name) {
        raise DuplicateName(kind~, name~)
      }
      meta.connectors[name] = link
    }
    "ObjectType" => {
      let name = json_string_field(def, kind, "name")
      let fields = match json_get(def, "fields") {
        Some(Json::Array(items)) => {
          let out : Array[ObjectTypeField] = []
          for item in items {
            let fname = json_string_field(item, kind, "name")
            let ftype = json_string_field(item, kind, "type")
            out.push({
              name: fname,
              field_type: parse_gql_type(ftype, kind, "fields[].type"),
              column: match json_opt_string_field(item, kind, "column") {
                Some(c) => c
                None => fname
              },
              description: json_opt_string_field(item, kind, "description"),
            })
          }
          out
        }
        _ => raise MissingField(kind~, field="fields")
      }
      let ot : ObjectTypeDef = {
        name,
        graphql_type_name: match
          json_opt_string_field(def, kind, "graphqlTypeName") {
          Some(g) => g
          None => name
        },
        fields,
        description: json_opt_string_field(def, kind, "description"),
      }
      if meta.object_types.contains(name) {
        raise DuplicateName(kind~, name~)
      }
      meta.object_types[name] = ot
    }
    "Model" => {
      let name = json_string_field(def, kind, "name")
      let source = match json_get(def, "source") {
        Some(s) => s
        None => raise MissingField(kind~, field="source")
      }
      let primary_key = json_string_array_field(def, kind, "primaryKey")
      let select_many_name = match
        json_opt_string_field(def, kind, "selectManyName") {
        Some(n) => n
        None => name
      }
      let select_uniques : Array[(String, Array[String])] = []
      match json_get(def, "selectUniques") {
        Some(Json::Array(items)) =>
          for item in items {
            let root = json_string_field(item, kind, "queryRootField")
            let keys = json_string_array_field(item, kind, "uniqueIdentifier")
            select_uniques.push((root, keys))
          }
        _ => ()
      }
      let model : Model = {
        name,
        object_type: json_string_field(def, kind, "objectType"),
        connector: json_string_field(source, kind, "dataConnectorName"),
        collection: json_string_field(source, kind, "collection"),
        filterable_fields: json_string_array_field(
          def, kind, "filterableFields",
        ),
        orderable_fields: json_string_array_field(def, kind, "orderableFields"),
        primary_key,
        select_many_name,
        select_uniques,
        description: json_opt_string_field(def, kind, "description"),
      }
      if meta.models.contains(name) {
        raise DuplicateName(kind~, name~)
      }
      meta.models[name] = model
    }
    "Relationship" => {
      let name = json_string_field(def, kind, "name")
      let source_type = json_string_field(def, kind, "sourceType")
      let target_model = json_string_field(def, kind, "targetModel")
      let rel_type = json_string_field(def, kind, "relationshipType")
      let rkind : RelationshipKind = match rel_type {
        "Object" | "object" => RelObject
        "Array" | "array" => RelArray
        _ =>
          raise InvalidValue(
            kind~,
            field="relationshipType",
            message="must be Object or Array",
          )
      }
      let mapping : Array[(String, String)] = match json_get(def, "mapping") {
        Some(Json::Array(items)) => {
          let out = []
          for item in items {
            out.push(
              (
                json_string_field(item, kind, "sourceField"),
                json_string_field(item, kind, "targetField"),
              ),
            )
          }
          out
        }
        _ => raise MissingField(kind~, field="mapping")
      }
      let rel : Relationship = {
        name,
        source_type,
        target_model,
        mapping,
        kind: rkind,
        description: json_opt_string_field(def, kind, "description"),
      }
      match meta.relationships.get(source_type) {
        Some(arr) => arr.push(rel)
        None => meta.relationships[source_type] = [rel]
      }
    }
    "ModelPermissions" => {
      let model_name = json_string_field(def, kind, "modelName")
      let permissions : Array[ModelPermission] = []
      match json_get(def, "permissions") {
        Some(Json::Array(items)) =>
          for item in items {
            let role = json_string_field(item, kind, "role")
            let select = json_get(item, "select")
            let filter = match select {
              Some(s) =>
                match json_get(s, "filter") {
                  Some(Json::Null) | None => None
                  Some(f) => Some(f)
                }
              None => None
            }
            let insert = match json_get(item, "insert") {
              Some(Json::Null) | None => None
              Some(sec) =>
                Some(InsertPermission::{
                  columns: parse_permission_columns(sec),
                  presets: parse_permission_presets(sec, kind),
                  check: match json_get(sec, "check") {
                    Some(Json::Null) | None => None
                    Some(c) => Some(c)
                  },
                })
            }
            let update = match json_get(item, "update") {
              Some(Json::Null) | None => None
              Some(sec) =>
                Some(UpdatePermission::{
                  columns: parse_permission_columns(sec),
                  filter: match json_get(sec, "filter") {
                    Some(Json::Null) | None => None
                    Some(f) => Some(f)
                  },
                  presets: parse_permission_presets(sec, kind),
                  check: match json_get(sec, "check") {
                    Some(Json::Null) | None => None
                    Some(c) => Some(c)
                  },
                })
            }
            let delete = match json_get(item, "delete") {
              Some(Json::Null) | None => None
              Some(sec) =>
                Some(DeletePermission::{
                  filter: match json_get(sec, "filter") {
                    Some(Json::Null) | None => None
                    Some(f) => Some(f)
                  },
                })
            }
            permissions.push({
              role,
              filter,
              allow_subscriptions: false,
              insert,
              update,
              delete,
            })
          }
        _ => raise MissingField(kind~, field="permissions")
      }
      meta.model_permissions[model_name] = { model_name, permissions }
    }
    "TypePermissions" => {
      let type_name = json_string_field(def, kind, "typeName")
      let permissions : Array[TypePermission] = []
      match json_get(def, "permissions") {
        Some(Json::Array(items)) =>
          for item in items {
            let role = json_string_field(item, kind, "role")
            let allowed = match json_get(item, "output") {
              Some(o) => json_string_array_field(o, kind, "allowedFields")
              None => []
            }
            permissions.push({ role, allowed_fields: allowed })
          }
        _ => raise MissingField(kind~, field="permissions")
      }
      meta.type_permissions[type_name] = { type_name, permissions }
    }
    "AuthConfig" => {
      let auth : AuthConfig = {
        admin_secret: json_opt_string_field(def, kind, "adminSecret"),
        jwt_hs256_secret: json_opt_string_field(def, kind, "jwtHs256Secret"),
        jwt_hs256_secret_from_env: json_opt_string_field(
          def, kind, "jwtHs256SecretFromEnv",
        ),
      }
      meta.auth = Some(auth)
    }
    other => raise UnknownKind(other)
  }
}

///|
priv struct MetadataBuilder {
  connectors : Map[String, DataConnectorLink]
  object_types : Map[String, ObjectTypeDef]
  models : Map[String, Model]
  relationships : Map[String, Array[Relationship]]
  model_permissions : Map[String, ModelPermissions]
  type_permissions : Map[String, TypePermissions]
  mut auth : AuthConfig?
}

///|
/// YAML テキスト (マルチドキュメント可) からロード
pub fn load_yaml(text : String) -> Metadata raise MetadataError {
  let docs = @yaml.Yaml::load_from_string(text) catch {
    _ => raise MetadataParse("invalid YAML")
  }
  let jsons = docs.map(d => d.to_json())
  load_documents(jsons)
}

///|
/// JSON 値の配列 (各ドキュメント) からロード
pub fn load_documents(docs : Array[Json]) -> Metadata raise MetadataError {
  let builder : MetadataBuilder = {
    connectors: Map([]),
    object_types: Map([]),
    models: Map([]),
    relationships: Map([]),
    model_permissions: Map([]),
    type_permissions: Map([]),
    auth: None,
  }
  for doc in docs {
    // 空ドキュメント (--- のみ) はスキップ
    if doc is Json::Null {
      continue
    }
    load_document(builder, doc)
  }
  let meta : Metadata = {
    connectors: builder.connectors,
    object_types: builder.object_types,
    models: builder.models,
    relationships: builder.relationships,
    model_permissions: builder.model_permissions,
    type_permissions: builder.type_permissions,
    auth: builder.auth,
  }
  resolve(meta)
  meta
}

///|
/// 参照整合性の検証
fn resolve(meta : Metadata) -> Unit raise MetadataError {
  for name, model in meta.models {
    if !meta.object_types.contains(model.object_type) {
      raise UnknownReference(
        kind="ObjectType",
        name=model.object_type,
        referenced_from="Model \{name}",
      )
    }
    if !meta.connectors.contains(model.connector) {
      raise UnknownReference(
        kind="DataConnectorLink",
        name=model.connector,
        referenced_from="Model \{name}",
      )
    }
    let ot = meta.object_types.get(model.object_type).unwrap()
    let field_names = ot.fields.map(f => f.name)
    for f in model.filterable_fields {
      if !field_names.contains(f) {
        raise UnknownReference(
          kind="field",
          name=f,
          referenced_from="Model \{name} filterableFields",
        )
      }
    }
    for f in model.orderable_fields {
      if !field_names.contains(f) {
        raise UnknownReference(
          kind="field",
          name=f,
          referenced_from="Model \{name} orderableFields",
        )
      }
    }
    for f in model.primary_key {
      if !field_names.contains(f) {
        raise UnknownReference(
          kind="field",
          name=f,
          referenced_from="Model \{name} primaryKey",
        )
      }
    }
  }
  for source_type, rels in meta.relationships {
    if !meta.object_types.contains(source_type) {
      raise UnknownReference(
        kind="ObjectType",
        name=source_type,
        referenced_from="Relationship sourceType",
      )
    }
    for rel in rels {
      if !meta.models.contains(rel.target_model) {
        raise UnknownReference(
          kind="Model",
          name=rel.target_model,
          referenced_from="Relationship \{rel.name}",
        )
      }
    }
  }
  for model_name, _ in meta.model_permissions {
    if !meta.models.contains(model_name) {
      raise UnknownReference(
        kind="Model",
        name=model_name,
        referenced_from="ModelPermissions",
      )
    }
  }
  for type_name, _ in meta.type_permissions {
    if !meta.object_types.contains(type_name) {
      raise UnknownReference(
        kind="ObjectType",
        name=type_name,
        referenced_from="TypePermissions",
      )
    }
  }
}
