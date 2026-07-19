// Hasura V3 (OpenDD) メタデータ JSON の互換ローダ。
// {version, subgraphs: [{name, objects: [{kind, version, definition}]}]} 形式
// (および素の objects 配列) を Mosura の Metadata に変換する。
//
// 対応 kind: ObjectType / Model / Relationship / ModelPermissions /
//            TypePermissions / DataConnectorLink / ObjectBooleanExpressionType (間接)
// それ以外の kind は読み飛ばし、skipped として報告する。

///|
/// 変換結果 (メタデータ + 読み飛ばした kind の一覧)
pub(all) struct V3LoadResult {
  metadata : Metadata
  skipped_kinds : Array[String]
}

///|
/// V3 メタデータ JSON をロードする。
/// auto_stub_connectors: 参照されているが未定義の DataConnectorLink を
/// スタブとして自動生成する (テストフィクスチャは接続定義を共通ファイルに
/// 分離しているため)
pub fn load_v3_metadata(
  j : Json,
  auto_stub_connectors? : Bool = false,
) -> V3LoadResult raise MetadataError {
  // 全 subgraph の objects を平坦化
  let objects : Array[Json] = []
  match j {
    Json::Array(items) =>
      for item in items {
        objects.push(item)
      }
    Json::Object(_) =>
      match jv3_get(j, "subgraphs") {
        Some(Json::Array(subgraphs)) =>
          for sg in subgraphs {
            match jv3_get(sg, "objects") {
              Some(Json::Array(items)) =>
                for item in items {
                  objects.push(item)
                }
              _ => ()
            }
          }
        _ => raise MetadataParse("v3 metadata must have subgraphs")
      }
    _ => raise MetadataParse("v3 metadata must be an object or array")
  }

  // 1 パス目: ObjectBooleanExpressionType (Model.filterExpressionType の解決に使う)
  let bool_exps : Map[String, Array[String]] = Map([])
  for obj in objects {
    if v3_kind(obj) == "ObjectBooleanExpressionType" {
      let def = v3_def(obj)
      let name = jv3_str(def, "name")
      let fields : Array[String] = []
      match jv3_get(def, "comparableFields") {
        Some(Json::Array(items)) =>
          for item in items {
            fields.push(jv3_str(item, "fieldName"))
          }
        _ => ()
      }
      bool_exps[name] = fields
    }
  }

  // 2 パス目: 変換
  let docs : Array[Json] = []
  let skipped : Map[String, Bool] = Map([])
  let referenced_connectors : Map[String, Bool] = Map([])
  let defined_connectors : Map[String, Bool] = Map([])
  for obj in objects {
    let kind = v3_kind(obj)
    match kind {
      "ObjectType" => docs.push(convert_object_type(obj))
      "Model" => {
        let (doc, connector) = convert_model(obj, bool_exps)
        docs.push(doc)
        referenced_connectors[connector] = true
      }
      "Relationship" =>
        match convert_relationship(obj) {
          Some(doc) => docs.push(doc)
          None => skipped["Relationship(command/unsupported)"] = true
        }
      "ModelPermissions" =>
        match convert_model_permissions(obj) {
          Some(doc) => docs.push(doc)
          None => skipped["ModelPermissions(rules-based)"] = true
        }
      "TypePermissions" =>
        match convert_type_permissions(obj) {
          Some(doc) => docs.push(doc)
          None => skipped["TypePermissions(rules-based)"] = true
        }
      "DataConnectorLink" => {
        let def = v3_def(obj)
        let name = jv3_str(def, "name")
        defined_connectors[name] = true
        docs.push(mk_connector_doc(name))
      }
      "ObjectBooleanExpressionType" => ()
      other => skipped[other] = true
    }
  }
  // 参照されているが未定義の connector をスタブ生成
  if auto_stub_connectors {
    for name, _ in referenced_connectors {
      if !defined_connectors.contains(name) {
        docs.push(mk_connector_doc(name))
      }
    }
  }
  // 部分スーパーグラフ (別 subgraph に定義がある前提のメタデータ) を許容するため、
  // 参照先が存在しない Relationship / ModelPermissions / TypePermissions を除外する
  let model_names : Map[String, Bool] = Map([])
  let type_names : Map[String, Bool] = Map([])
  for doc in docs {
    let kind = match jv3_get(doc, "kind") {
      Some(Json::String(k)) => k
      _ => ""
    }
    let def = jv3_get(doc, "definition").unwrap()
    if kind == "Model" {
      model_names[jv3_str(def, "name")] = true
    }
    if kind == "ObjectType" {
      type_names[jv3_str(def, "name")] = true
    }
  }
  let filtered : Array[Json] = []
  for doc in docs {
    let kind = match jv3_get(doc, "kind") {
      Some(Json::String(k)) => k
      _ => ""
    }
    let def = jv3_get(doc, "definition").unwrap()
    let keep = match kind {
      "Relationship" => {
        let target_ok = match jv3_get(def, "targetModel") {
          Some(Json::String(t)) => model_names.contains(t)
          _ => false
        }
        let source_ok = match jv3_get(def, "sourceType") {
          Some(Json::String(st)) => type_names.contains(st)
          _ => false
        }
        target_ok && source_ok
      }
      "ModelPermissions" =>
        match jv3_get(def, "modelName") {
          Some(Json::String(m)) => model_names.contains(m)
          _ => false
        }
      "TypePermissions" =>
        match jv3_get(def, "typeName") {
          Some(Json::String(t)) => type_names.contains(t)
          _ => false
        }
      _ => true
    }
    if keep {
      filtered.push(doc)
    } else {
      skipped["\{kind}(dangling reference / partial supergraph)"] = true
    }
  }
  let metadata = load_documents(filtered)
  { metadata, skipped_kinds: skipped.keys().collect() }
}

///|
fn jv3_get(j : Json, key : String) -> Json? {
  match j {
    Json::Object(m) => m.get(key)
    _ => None
  }
}

///|
fn jv3_str(j : Json, key : String) -> String raise MetadataError {
  match jv3_get(j, key) {
    Some(Json::String(s)) => s
    _ => raise MetadataParse("expected string at '\{key}' in v3 metadata")
  }
}

///|
fn v3_kind(obj : Json) -> String {
  match jv3_get(obj, "kind") {
    Some(Json::String(k)) => k
    _ => ""
  }
}

///|
fn v3_def(obj : Json) -> Json raise MetadataError {
  match jv3_get(obj, "definition") {
    Some(d) => d
    None => raise MetadataParse("v3 object missing definition")
  }
}

///|
fn mk_doc(kind : String, definition : Json) -> Json {
  let m : Map[String, Json] = {
    "kind": Json::string(kind),
    "version": Json::string("v1"),
    "definition": definition,
  }
  Json::object(m)
}

///|
fn mk_connector_doc(name : String) -> Json {
  let conn : Map[String, Json] = { "urlFromEnv": Json::string("PG_MAIN_URL") }
  let def : Map[String, Json] = {
    "name": Json::string(name),
    "connection": Json::object(conn),
  }
  mk_doc("DataConnectorLink", Json::object(def))
}

///|
/// ObjectType: graphql.typeName と dataConnectorTypeMapping の column を反映
fn convert_object_type(obj : Json) -> Json raise MetadataError {
  let def = v3_def(obj)
  let name = jv3_str(def, "name")
  // カラムマッピング (最初の dataConnectorTypeMapping を採用)
  let column_of : Map[String, String] = Map([])
  match jv3_get(def, "dataConnectorTypeMapping") {
    Some(Json::Array([first, ..])) =>
      match jv3_get(first, "fieldMapping") {
        Some(Json::Object(fm)) =>
          for fname, entry in fm {
            match jv3_get(entry, "column") {
              Some(col) =>
                match jv3_get(col, "name") {
                  Some(Json::String(cname)) => column_of[fname] = cname
                  _ => ()
                }
              None => ()
            }
          }
        _ => ()
      }
    _ => ()
  }
  let fields : Array[Json] = []
  match jv3_get(def, "fields") {
    Some(Json::Array(items)) =>
      for item in items {
        let fname = jv3_str(item, "name")
        let ftype = match jv3_get(item, "type") {
          Some(Json::String(t)) => t
          // v3 の型は文字列表記のみ対応 (オブジェクト表記の型は未対応)
          _ =>
            raise MetadataParse(
              "unsupported field type format in v3 ObjectType '\{name}'",
            )
        }
        let f : Map[String, Json] = {
          "name": Json::string(fname),
          "type": Json::string(ftype),
        }
        match column_of.get(fname) {
          Some(c) => f["column"] = Json::string(c)
          None => ()
        }
        fields.push(Json::object(f))
      }
    _ => raise MetadataParse("v3 ObjectType '\{name}' missing fields")
  }
  let out : Map[String, Json] = {
    "name": Json::string(name),
    "fields": Json::array(fields),
  }
  match jv3_get(def, "graphql") {
    Some(g) =>
      match jv3_get(g, "typeName") {
        Some(Json::String(tn)) => out["graphqlTypeName"] = Json::string(tn)
        _ => ()
      }
    None => ()
  }
  mk_doc("ObjectType", Json::object(out))
}

///|
/// Model: source / orderableFields / filterExpressionType / graphql.{selectMany,selectUniques}
fn convert_model(
  obj : Json,
  bool_exps : Map[String, Array[String]],
) -> (Json, String) raise MetadataError {
  let def = v3_def(obj)
  let name = jv3_str(def, "name")
  let source = match jv3_get(def, "source") {
    Some(s) => s
    None => raise MetadataParse("v3 Model '\{name}' has no source")
  }
  let connector = jv3_str(source, "dataConnectorName")
  let orderable : Array[Json] = []
  match jv3_get(def, "orderableFields") {
    Some(Json::Array(items)) =>
      for item in items {
        orderable.push(Json::string(jv3_str(item, "fieldName")))
      }
    _ => ()
  }
  // filterExpressionType → ObjectBooleanExpressionType.comparableFields
  let filterable : Array[Json] = []
  match jv3_get(def, "filterExpressionType") {
    Some(Json::String(bexp_name)) =>
      match bool_exps.get(bexp_name) {
        Some(fields) =>
          for f in fields {
            filterable.push(Json::string(f))
          }
        // 新形式 BooleanExpressionType (kind 未対応) の場合はフィルタなしにフォールバック
        None => ()
      }
    _ => ()
  }
  let out : Map[String, Json] = {
    "name": Json::string(name),
    "objectType": jv3_get(def, "objectType").unwrap(),
    "source": {
      let s : Map[String, Json] = {
        "dataConnectorName": Json::string(connector),
        "collection": jv3_get(source, "collection").unwrap(),
      }
      Json::object(s)
    },
    "orderableFields": Json::array(orderable),
    "filterableFields": Json::array(filterable),
  }
  // graphql root フィールド名
  match jv3_get(def, "graphql") {
    Some(g) => {
      match jv3_get(g, "selectMany") {
        Some(sm) =>
          match jv3_get(sm, "queryRootField") {
            Some(Json::String(n)) => out["selectManyName"] = Json::string(n)
            _ => ()
          }
        None => ()
      }
      match jv3_get(g, "selectUniques") {
        Some(Json::Array(items)) => {
          let uniques : Array[Json] = []
          for item in items {
            let root = jv3_str(item, "queryRootField")
            let keys : Array[Json] = []
            match jv3_get(item, "uniqueIdentifier") {
              Some(Json::Array(ks)) =>
                for k in ks {
                  keys.push(k)
                }
              _ => ()
            }
            let u : Map[String, Json] = {
              "queryRootField": Json::string(root),
              "uniqueIdentifier": Json::array(keys),
            }
            uniques.push(Json::object(u))
          }
          out["selectUniques"] = Json::array(uniques)
        }
        _ => ()
      }
    }
    None => ()
  }
  (mk_doc("Model", Json::object(out)), connector)
}

///|
/// Relationship: model ターゲットのみ対応 (command ターゲットは None)
fn convert_relationship(obj : Json) -> Json? raise MetadataError {
  let def = v3_def(obj)
  let name = jv3_str(def, "name")
  // 新表記 sourceType / 旧表記 source の両方を受ける
  let source_type = match jv3_get(def, "sourceType") {
    Some(Json::String(s)) => s
    _ =>
      match jv3_get(def, "source") {
        Some(Json::String(s)) => s
        _ => return None // 未知の表記
      }
  }
  let target = match jv3_get(def, "target") {
    Some(t) => t
    None => raise MetadataParse("v3 Relationship '\{name}' has no target")
  }
  let model_target = match jv3_get(target, "model") {
    Some(m) => m
    None => return None // command ターゲット等
  }
  let target_model = jv3_str(model_target, "name")
  let rel_type = jv3_str(model_target, "relationshipType")
  let mapping : Array[Json] = []
  match jv3_get(def, "mapping") {
    Some(Json::Array(items)) =>
      for item in items {
        // source.fieldPath[0].fieldName / target.modelField[0].fieldName
        let source_field = match jv3_get(item, "source") {
          Some(s) =>
            match jv3_get(s, "fieldPath") {
              Some(Json::Array([first, ..])) => jv3_str(first, "fieldName")
              _ => return None // ネストパスは未対応
            }
          None => return None
        }
        let target_field = match jv3_get(item, "target") {
          Some(t) =>
            match jv3_get(t, "modelField") {
              Some(Json::Array([first, ..])) => jv3_str(first, "fieldName")
              _ => return None
            }
          None => return None
        }
        let m : Map[String, Json] = {
          "sourceField": Json::string(source_field),
          "targetField": Json::string(target_field),
        }
        mapping.push(Json::object(m))
      }
    _ => ()
  }
  let out : Map[String, Json] = {
    "name": Json::string(name),
    "sourceType": Json::string(source_type),
    "targetModel": Json::string(target_model),
    "relationshipType": Json::string(rel_type),
    "mapping": Json::array(mapping),
  }
  Some(mk_doc("Relationship", Json::object(out)))
}

///|
/// ModelPermissions: filter はそのまま透過 (fieldComparison / and / or / not 形式)。
/// v2 の rules-based 形式 (permissions 配列なし) は未対応のため None
fn convert_model_permissions(obj : Json) -> Json? raise MetadataError {
  let def = v3_def(obj)
  match jv3_get(def, "permissions") {
    Some(Json::Array(_)) => Some(mk_doc("ModelPermissions", def))
    _ => None
  }
}

///|
fn convert_type_permissions(obj : Json) -> Json? raise MetadataError {
  let def = v3_def(obj)
  match jv3_get(def, "permissions") {
    Some(Json::Array(_)) => Some(mk_doc("TypePermissions", def))
    _ => None
  }
}
