// Hasura V3 (OpenDD) メタデータ JSON の互換ローダ。
// {version, subgraphs: [{name, objects: [{kind, version, definition}]}]} 形式
// (および素の objects 配列) を Mosura の Metadata に変換する。
//
// 対応 kind: ObjectType / Model / Relationship / ModelPermissions /
//            TypePermissions / DataConnectorLink /
//            ObjectBooleanExpressionType・BooleanExpressionType (間接 —
//            Model.filterExpressionType の解決に使う)
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

  // 1 パス目 (order): OrderByExpression (Model v2 の orderByExpression 参照の解決に使う)。
  // object operand の orderableFields から並べ替え可能フィールド名を取り出す。
  // scalar operand (フィールド単位の方向設定) は Model からは参照されない
  let order_exps : Map[String, Array[String]] = Map([])
  for obj in objects {
    if v3_kind(obj) == "OrderByExpression" {
      let def = v3_def(obj)
      let name = jv3_str(def, "name")
      let fields : Array[String] = []
      match jv3_get(def, "operand") {
        Some(operand) =>
          match jv3_get(operand, "object") {
            Some(object_operand) =>
              match jv3_get(object_operand, "orderableFields") {
                Some(Json::Array(items)) =>
                  for item in items {
                    fields.push(jv3_str(item, "fieldName"))
                  }
                _ => ()
              }
            None => ()
          }
        None => ()
      }
      order_exps[name] = fields
    }
  }

  // 1 パス目: boolean expression 型 (Model.filterExpressionType の解決に使う)。
  // 旧 ObjectBooleanExpressionType (2024-11-18 以降の V3 ではビルドエラー) と
  // 新形式 BooleanExpressionType (operand.object) の両方を受ける
  let bool_exps : Map[String, Array[String]] = Map([])
  for obj in objects {
    match v3_kind(obj) {
      "ObjectBooleanExpressionType" => {
        let def = v3_def(obj)
        bool_exps[jv3_str(def, "name")] = comparable_field_names(def)
      }
      "BooleanExpressionType" => {
        let def = v3_def(obj)
        // object operand のみが Model.filterExpressionType の対象。
        // scalar operand (フィールド単位の比較演算子定義) はここでは不要。
        // comparableRelationships (リレーション述語) は未対応 (#32 / #38)
        match jv3_get(def, "operand") {
          Some(operand) =>
            match jv3_get(operand, "object") {
              Some(object_operand) =>
                bool_exps[jv3_str(def, "name")] = comparable_field_names(
                  object_operand,
                )
              None => ()
            }
          None => ()
        }
      }
      _ => ()
    }
  }

  // 1 パス目: AggregateExpression。定義を収集して接続非依存の検証を行い、
  // Model.aggregateExpression の fail-closed 解決に使う operand 種別マップを返す。
  // オブジェクト型のフィールド名集合 (aggregatableField 存在チェック用) は
  // 生の ObjectType 定義から作る (オブジェクト表記フィールドで読み飛ばした
  // ObjectType も対象にするため、変換後 docs ではなく生 JSON から取る)。
  let object_type_fields : Map[String, Map[String, Bool]] = Map([])
  for obj in objects {
    if v3_kind(obj) == "ObjectType" {
      let def = v3_def(obj)
      let fset : Map[String, Bool] = Map([])
      match jv3_get(def, "fields") {
        Some(Json::Array(items)) =>
          for item in items {
            fset[jv3_str(item, "name")] = true
          }
        _ => ()
      }
      object_type_fields[jv3_str(def, "name")] = fset
    }
  }
  let agg_exps : Map[String, AggOperandKind] = collect_and_validate_aggregate_expressions(
    objects, object_type_fields,
  )

  // OpenDD フラグ require_valid_ndc_v01_version: NDC v0.1 の無効な
  // capabilities バージョンを警告ではなくビルドエラーに昇格させる
  let require_valid_ndc_v01 = match jv3_get(j, "flags") {
    Some(flags) =>
      match jv3_get(flags, "require_valid_ndc_v01_version") {
        Some(Json::True) => true
        _ => false
      }
    None => false
  }

  // 2 パス目: 変換
  let docs : Array[Json] = []
  let skipped : Map[String, Bool] = Map([])
  let referenced_connectors : Map[String, Bool] = Map([])
  let defined_connectors : Map[String, Bool] = Map([])
  for obj in objects {
    let kind = v3_kind(obj)
    match kind {
      "ObjectType" =>
        match convert_object_type(obj) {
          Some(doc) => docs.push(doc)
          None => skipped["ObjectType(unsupported field type)"] = true
        }
      "Model" => {
        let (doc, connector) = convert_model(
          obj, bool_exps, order_exps, agg_exps,
        )
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
        // 実接続の NDC schema/capabilities バージョンを保持・検証する。
        // schema を持たない (スタブ相当の) 定義は None のまま素通し。
        let (ndc_version, capabilities_version) = match jv3_get(def, "schema") {
          Some(schema) => {
            let sv = match jv3_get(schema, "version") {
              Some(Json::String(v)) => Some(v)
              _ => None
            }
            let cv = match jv3_get(schema, "capabilities") {
              Some(caps) =>
                match jv3_get(caps, "version") {
                  Some(Json::String(v)) => Some(v)
                  _ => None
                }
              None => None
            }
            match (sv, cv) {
              (Some(s), Some(c)) =>
                validate_ndc_capabilities_version(
                  name, s, c, require_valid_ndc_v01,
                )
              _ => ()
            }
            (sv, cv)
          }
          None => (None, None)
        }
        docs.push(mk_connector_doc(name, ndc_version, capabilities_version))
      }
      "ObjectBooleanExpressionType" | "BooleanExpressionType" => ()
      // OrderByExpression は 1 パス目で消費済み。GraphqlConfig は命名の
      // カスタマイズを未対応 (既定値を使用) だが、存在自体はエラーにしない
      "OrderByExpression" => ()
      "GraphqlConfig" =>
        skipped["GraphqlConfig(naming not honored — defaults used)"] = true
      "ScalarType" => {
        // Mosura はスカラー型レジストリを持たないため定義自体は読み飛ばすが、
        // 組込スカラー名 (ID/Int/String/Boolean/Float) との衝突は V3 と同様に
        // ビルドエラーにする (2024-09-26 互換性チェック)
        let sname = jv3_str(v3_def(obj), "name")
        if ["ID", "Int", "String", "Boolean", "Float"].contains(sname) {
          raise MetadataParse(
            "v3 ScalarType '\{sname}' conflicts with a built-in scalar type name",
          )
        }
        skipped["ScalarType"] = true
      }
      other => skipped[other] = true
    }
  }
  // 参照されているが未定義の connector をスタブ生成
  if auto_stub_connectors {
    for name, _ in referenced_connectors {
      if !defined_connectors.contains(name) {
        // スタブ接続は schema/capabilities を持たないため検証しない
        docs.push(mk_connector_doc(name, None, None))
      }
    }
  }
  // 部分スーパーグラフ (別 subgraph に定義がある前提のメタデータ) と、
  // 未対応フィールド型で読み飛ばした ObjectType を許容するため、参照先が
  // 存在しない Model / Relationship / ModelPermissions / TypePermissions を除外する。
  // type_names は生成された ObjectType (skip 済みは含まない) から作り、
  // model_names は objectType が解決できる Model のみを含める
  let type_names : Map[String, Bool] = Map([])
  for doc in docs {
    match jv3_get(doc, "kind") {
      Some(Json::String("ObjectType")) => {
        let def = jv3_get(doc, "definition").unwrap()
        type_names[jv3_str(def, "name")] = true
      }
      _ => ()
    }
  }
  let model_names : Map[String, Bool] = Map([])
  for doc in docs {
    match jv3_get(doc, "kind") {
      Some(Json::String("Model")) => {
        let def = jv3_get(doc, "definition").unwrap()
        let ot_ok = match jv3_get(def, "objectType") {
          Some(Json::String(ot)) => type_names.contains(ot)
          _ => false
        }
        if ot_ok {
          model_names[jv3_str(def, "name")] = true
        }
      }
      _ => ()
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
      "Model" =>
        match jv3_get(def, "name") {
          Some(Json::String(m)) => model_names.contains(m)
          _ => false
        }
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
/// comparableFields 配列 (旧 kind の definition 直下 / 新 kind の object operand 下)
/// から fieldName の一覧を取り出す
fn comparable_field_names(
  container : Json,
) -> Array[String] raise MetadataError {
  let fields : Array[String] = []
  let seen : Map[String, Bool] = Map([])
  match jv3_get(container, "comparableFields") {
    Some(Json::Array(items)) =>
      for item in items {
        let fname = jv3_str(item, "fieldName")
        // 同一フィールドを comparableFields に重複登録するのは V3 ではビルドエラー
        if seen.contains(fname) {
          raise MetadataParse(
            "duplicate comparableField '\{fname}' in boolean expression type",
          )
        }
        seen[fname] = true
        fields.push(fname)
      }
    _ => ()
  }
  fields
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
/// 検証済みの DataConnectorLink ドキュメントを組み立てる。url は実行時テスト用の
/// 環境変数へ落とし込む従来挙動を維持しつつ、検証済みの NDC バージョン情報を
/// 埋め込む (loader が DataConnectorLink の enriched フィールドに反映する)。
fn mk_connector_doc(
  name : String,
  ndc_version : String?,
  capabilities_version : String?,
) -> Json {
  let conn : Map[String, Json] = { "urlFromEnv": Json::string("PG_MAIN_URL") }
  let def : Map[String, Json] = {
    "name": Json::string(name),
    "connection": Json::object(conn),
  }
  match ndc_version {
    Some(v) => def["ndcVersion"] = Json::string(v)
    None => ()
  }
  match capabilities_version {
    Some(v) => def["capabilitiesVersion"] = Json::string(v)
    None => ()
  }
  mk_doc("DataConnectorLink", Json::object(def))
}

///|
/// NDC capabilities のバージョン検証 (upstream metadata-resolve
/// stages/data_connectors/types.rs の validate_ndc_version 相当)。
///
/// schema_version: DataConnectorLink.schema.version。"v0.1" → NDC v0.1.x /
///   "v0.2" → NDC v0.2.x。それ以外は検証対象外 (upstream は OpenDD enum で弾く)。
/// capabilities_version: schema.capabilities.version の文字列。
/// require_valid_ndc_v01: OpenDD フラグ require_valid_ndc_v01_version。
///
/// 判定: NDC v0.1.x は semver `^0.1.0` (= 0.1.x)、v0.2.x は `^0.2.0` (= 0.2.x)
/// に一致しなければならない。
/// - 一致しない有効 semver → IncompatibleNdcVersion 相当 (常にエラー)
/// - 無効 semver かつ v0.2 → InvalidNdcVersion 相当 (常にエラー)
/// - 無効 semver かつ v0.1 → 旧ビルド後方互換の警告。フラグ時のみエラーに昇格
fn validate_ndc_capabilities_version(
  connector_name : String,
  schema_version : String,
  capabilities_version : String,
  require_valid_ndc_v01 : Bool,
) -> Unit raise MetadataError {
  let expected_minor = match schema_version {
    "v0.1" => 1
    "v0.2" => 2
    _ => return
  }
  match parse_exact_semver(capabilities_version) {
    Some((major, minor, _)) =>
      if !(major == 0 && minor == expected_minor) {
        raise InvalidValue(
          kind="DataConnectorLink",
          field="schema.capabilities.version",
          message="connector '\{connector_name}': capabilities version '\{capabilities_version}' is incompatible with NDC schema version '\{schema_version}' (requires ^0.\{expected_minor}.0)",
        )
      }
    None =>
      if expected_minor == 2 {
        raise InvalidValue(
          kind="DataConnectorLink",
          field="schema.capabilities.version",
          message="connector '\{connector_name}': invalid NDC v0.2 capabilities version '\{capabilities_version}'",
        )
      } else if require_valid_ndc_v01 {
        raise InvalidValue(
          kind="DataConnectorLink",
          field="schema.capabilities.version",
          message="connector '\{connector_name}': invalid NDC v0.1 capabilities version '\{capabilities_version}'",
        )
      }
  }
}

///|
/// semver 文字列を厳密な major.minor.patch (3 個の非負整数) として解釈する。
/// pre-release / build metadata や要素数の過不足はすべて無効 (None) とみなす。
/// "^0.1.0" / "" / "*" / "v0.1" 等はいずれも None。
fn parse_exact_semver(s : String) -> (Int, Int, Int)? {
  let parts = s.split(".").map(p => p.to_owned()).collect()
  if parts.length() != 3 {
    return None
  }
  match
    (
      parse_nonneg_int(parts[0]),
      parse_nonneg_int(parts[1]),
      parse_nonneg_int(parts[2]),
    ) {
    (Some(a), Some(b), Some(c)) => Some((a, b, c))
    _ => None
  }
}

///|
/// 非負整数文字列を Int に解釈する (空文字・非数字を含む場合は None)
fn parse_nonneg_int(s : String) -> Int? {
  let chars = s.to_array()
  if chars.length() == 0 {
    return None
  }
  let mut acc = 0
  for c in chars {
    let v = c.to_int()
    if v < '0'.to_int() || v > '9'.to_int() {
      return None
    }
    acc = acc * 10 + (v - '0'.to_int())
  }
  Some(acc)
}

///|
/// ObjectType: graphql.typeName と dataConnectorTypeMapping の column を反映。
/// フィールド型がスカラー文字列表記 ("Int!" 等) でない (オブジェクト表記の型)
/// 場合は、その ObjectType だけを None として読み飛ばす (ロード全体は落とさない)。
/// 参照する Model は後段の dangling-reference フィルタで除外される
fn convert_object_type(obj : Json) -> Json? raise MetadataError {
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
          // v3 の型は文字列表記のみ対応。オブジェクト表記の型が来たら
          // この ObjectType 自体を読み飛ばす (ロード全体は失敗させない)
          _ => return None
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
  Some(mk_doc("ObjectType", Json::object(out)))
}

///|
/// Model: source / orderableFields / filterExpressionType / graphql.{selectMany,selectUniques}
fn convert_model(
  obj : Json,
  bool_exps : Map[String, Array[String]],
  order_exps : Map[String, Array[String]],
  agg_exps : Map[String, AggOperandKind],
) -> (Json, String) raise MetadataError {
  let def = v3_def(obj)
  let name = jv3_str(def, "name")
  // aggregateExpression → AggregateExpression の解決。
  // filterExpressionType と同様に fail-closed: 未解決参照は黙って落とさず拒否する。
  // また operand の object 型が Model の objectType と一致しない場合も拒否する
  // (V3 の model_aggregate_exp_type_mismatch 相当)。
  match jv3_get(def, "aggregateExpression") {
    Some(Json::String(agg_name)) =>
      match agg_exps.get(agg_name) {
        Some(AggObject(operand_type)) => {
          let model_object_type = match jv3_get(def, "objectType") {
            Some(Json::String(ot)) => ot
            _ =>
              raise MetadataParse("v3 Model '\{name}' has no objectType string")
          }
          if operand_type != model_object_type {
            raise MetadataParse(
              "v3 Model '\{name}': aggregateExpression '\{agg_name}' aggregates over '\{operand_type}' but the model's object type is '\{model_object_type}'",
            )
          }
        }
        Some(AggScalar(scalar_type)) =>
          // scalar operand の aggregate expression は object 型の Model には使えない
          raise MetadataParse(
            "v3 Model '\{name}': aggregateExpression '\{agg_name}' aggregates over scalar type '\{scalar_type}', not the model's object type",
          )
        None =>
          raise MetadataParse(
            "v3 Model '\{name}': aggregateExpression '\{agg_name}' does not resolve to a known AggregateExpression (refusing to silently drop aggregates)",
          )
      }
    _ => ()
  }
  let source = match jv3_get(def, "source") {
    Some(s) => s
    None => raise MetadataParse("v3 Model '\{name}' has no source")
  }
  let connector = jv3_str(source, "dataConnectorName")
  // orderable フィールド: v1 は orderableFields、v2 は orderByExpression 参照。
  // v2 の orderByExpression が解決できない場合は fail-closed で拒否する
  // (黙って order_by 不可にすると V3 の挙動と食い違う)
  let orderable : Array[Json] = []
  match jv3_get(def, "orderableFields") {
    Some(Json::Array(items)) =>
      for item in items {
        orderable.push(Json::string(jv3_str(item, "fieldName")))
      }
    _ =>
      match jv3_get(def, "orderByExpression") {
        Some(Json::String(obe_name)) =>
          match order_exps.get(obe_name) {
            Some(fields) =>
              for f in fields {
                orderable.push(Json::string(f))
              }
            None =>
              raise MetadataParse(
                "v3 Model '\{name}': orderByExpression '\{obe_name}' does not resolve to a known OrderByExpression",
              )
          }
        _ => ()
      }
  }
  // filterExpressionType → (Object)BooleanExpressionType の comparableFields。
  // 解決できない参照はサイレントに「フィルタなし」へ落とさず fail-closed で拒否する
  // (黙って落とすと where 可能フィールドが消え、権限 filter の前提も崩れる)
  let filterable : Array[Json] = []
  match jv3_get(def, "filterExpressionType") {
    Some(Json::String(bexp_name)) =>
      match bool_exps.get(bexp_name) {
        Some(fields) =>
          for f in fields {
            filterable.push(Json::string(f))
          }
        None =>
          raise MetadataParse(
            "v3 Model '\{name}': filterExpressionType '\{bexp_name}' does not resolve to a known ObjectBooleanExpressionType / BooleanExpressionType (refusing to silently drop filters)",
          )
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
/// AggregateExpression の operand 種別 (Model の型整合チェック用)
priv enum AggOperandKind {
  AggObject(String) // object operand: aggregatedType (object 型名)
  AggScalar(String) // scalar operand: aggregatedType (スカラー型名)
}

///|
/// 型表記文字列から nullable (!) / list ([]) のラッパを取り除いて素の型名を得る
fn strip_type_wrappers(t : String) -> String {
  let mut s = t
  while true {
    if s.has_suffix("!") {
      s = s[0:s.length() - 1].to_owned()
    } else if s.has_prefix("[") && s.has_suffix("]") {
      s = s[1:s.length() - 1].to_owned()
    } else {
      break
    }
  }
  s
}

///|
/// AggregateExpression 定義を収集し、接続非依存の検証を行う。
/// 接続 (data connector) に依存する検証 (関数マッピング・スカラー表現・capability・
/// count 戻り値の表現整合 等) は Mosura が connector をスタブ化しているため実装しない。
/// 返り値: aggregate expression 名 → operand 種別 (Model.aggregateExpression 解決用)。
///
/// 実装する検証 (upstream metadata-resolve/stages/aggregates 由来):
/// - DuplicateAggregateExpressionDefinition (同名重複)
/// - AggregateOperandObjectTypeNotFound (object operand の型が未定義)
/// - AggregateOperandObjectFieldDuplicated (aggregatableField 重複)
/// - AggregateOperandObjectFieldNotFound (aggregatableField が operand 型に無い)
/// - AggregateOperandObjectFieldAggregateExpressionNotFound (参照先 agg exp が無い)
/// - AggregateOperandFunctionDuplicated (aggregationFunction 名の重複)
/// - Aggregatable/AggregationFunctionNameConflict (count 既定名 _count/_count_distinct と衝突)
/// - InvalidCountReturnType (count/countDistinct の戻り値が Int 以外の組込型)
fn collect_and_validate_aggregate_expressions(
  objects : Array[Json],
  object_type_fields : Map[String, Map[String, Bool]],
) -> Map[String, AggOperandKind] raise MetadataError {
  // フェーズ A: 全 aggregate expression 名と operand 種別を収集 (同名重複を検出)
  let agg_exps : Map[String, AggOperandKind] = Map([])
  for obj in objects {
    if v3_kind(obj) == "AggregateExpression" {
      let def = v3_def(obj)
      let name = jv3_str(def, "name")
      if agg_exps.contains(name) {
        raise MetadataParse(
          "v3 AggregateExpression '\{name}' is defined more than once",
        )
      }
      let operand = match jv3_get(def, "operand") {
        Some(o) => o
        None =>
          raise MetadataParse("v3 AggregateExpression '\{name}' has no operand")
      }
      let kind = match jv3_get(operand, "object") {
        Some(oo) => AggObject(jv3_str(oo, "aggregatedType"))
        None =>
          match jv3_get(operand, "scalar") {
            Some(so) => AggScalar(jv3_str(so, "aggregatedType"))
            None =>
              raise MetadataParse(
                "v3 AggregateExpression '\{name}' operand is neither object nor scalar",
              )
          }
      }
      agg_exps[name] = kind
    }
  }

  // フェーズ B: 各 aggregate expression の内部検証 (参照存在チェックには
  // フェーズ A で集めた全名集合が必要なため 2 段階)
  for obj in objects {
    if v3_kind(obj) == "AggregateExpression" {
      let def = v3_def(obj)
      let name = jv3_str(def, "name")
      let operand = jv3_get(def, "operand").unwrap()
      // GraphqlConfig 既定名。default GraphqlConfig を使う Mosura では
      // count/countDistinct のフィールド名は _count / _count_distinct 固定。
      let has_graphql = jv3_get(def, "graphql") is Some(_)
      match jv3_get(operand, "object") {
        Some(oo) => {
          let operand_type = jv3_str(oo, "aggregatedType")
          // object operand 型は既知の ObjectType でなければならない
          let fields = match object_type_fields.get(operand_type) {
            Some(f) => f
            None =>
              raise MetadataParse(
                "v3 AggregateExpression '\{name}': operand object type '\{operand_type}' cannot be found",
              )
          }
          let seen_fields : Map[String, Bool] = Map([])
          match jv3_get(oo, "aggregatableFields") {
            Some(Json::Array(items)) =>
              for item in items {
                let fname = jv3_str(item, "fieldName")
                if seen_fields.contains(fname) {
                  raise MetadataParse(
                    "v3 AggregateExpression '\{name}' has duplicate aggregatable field '\{fname}'",
                  )
                }
                seen_fields[fname] = true
                if !fields.contains(fname) {
                  raise MetadataParse(
                    "v3 AggregateExpression '\{name}': aggregatable field '\{fname}' does not exist on operand type '\{operand_type}'",
                  )
                }
                let field_agg = jv3_str(item, "aggregateExpression")
                if !agg_exps.contains(field_agg) {
                  raise MetadataParse(
                    "v3 AggregateExpression '\{name}': aggregatable field '\{fname}' references unknown AggregateExpression '\{field_agg}'",
                  )
                }
                // count 既定名との衝突 (aggregatable field 側)
                if has_graphql &&
                  (fname == "_count" || fname == "_count_distinct") {
                  raise MetadataParse(
                    "v3 AggregateExpression '\{name}': aggregatable field name '\{fname}' conflicts with the GraphqlConfig count field name",
                  )
                }
              }
            _ => ()
          }
        }
        None =>
          // scalar operand: aggregationFunctions の重複 / count 名衝突を検証
          match jv3_get(operand, "scalar") {
            Some(so) => {
              let seen_fns : Map[String, Bool] = Map([])
              match jv3_get(so, "aggregationFunctions") {
                Some(Json::Array(items)) =>
                  for item in items {
                    let fnname = jv3_str(item, "name")
                    if seen_fns.contains(fnname) {
                      raise MetadataParse(
                        "v3 AggregateExpression '\{name}' has duplicate aggregation function '\{fnname}'",
                      )
                    }
                    seen_fns[fnname] = true
                    if has_graphql &&
                      (fnname == "_count" || fnname == "_count_distinct") {
                      raise MetadataParse(
                        "v3 AggregateExpression '\{name}': aggregation function name '\{fnname}' conflicts with the GraphqlConfig count field name",
                      )
                    }
                  }
                _ => ()
              }
            }
            None => ()
          }
      }
      // count / countDistinct の戻り値: Int 以外の組込型は不可。
      // (未知のカスタム型チェック UnknownCountReturnType は Mosura がスカラー型
      //  レジストリを持たないため実装しない)
      for count_key in ["count", "countDistinct"] {
        match jv3_get(def, count_key) {
          Some(cdef) =>
            match jv3_get(cdef, "returnType") {
              Some(Json::String(rt)) => {
                let base = strip_type_wrappers(rt)
                if ["Float", "String", "Boolean", "ID"].contains(base) {
                  raise MetadataParse(
                    "v3 AggregateExpression '\{name}': \{count_key} return type '\{rt}' must be an integer type",
                  )
                }
              }
              _ => ()
            }
          None => ()
        }
      }
    }
  }
  agg_exps
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
