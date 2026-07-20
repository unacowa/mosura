// metadata-resolve フィクスチャ (V3 実データ) に対する互換ローダの検証。
//
// 検証の意味論 (docs/implementation-plan.md 参照):
// - passing/ : V3 が受理するメタデータを互換ローダも受理できること
//   (対象外 kind は読み飛ばし。V3 の resolve 結果スナップショットとの
//    バイト一致は Mosura の resolved モデルが意図的にサブセットのため対象外)
// - failing/ : V3 が拒否するメタデータのうち、Mosura が実装する検証
//   (参照整合性・重複名 等) で拒否できるケースを回帰として固定する

///|
fn v3_case_dirs(base : String) -> Array[String] raise {
  let out : Array[String] = []
  fn walk(dir : String) -> Unit raise {
    if @fs.path_exists("\{dir}/metadata.json") {
      out.push(dir)
      return
    }
    let entries = @fs.read_dir(dir)
    entries.sort()
    for e in entries {
      if @fs.is_dir("\{dir}/\{e}") {
        walk("\{dir}/\{e}")
      }
    }
  }
  walk(base)
  out
}

///|
fn try_load_v3(dir : String) -> Result[V3LoadResult, String] raise {
  let text = @fs.read_file_to_string("\{dir}/metadata.json")
  let j = @json.parse(text) catch { _ => return Err("invalid JSON") }
  let r = load_v3_metadata(j, auto_stub_connectors=true) catch {
    e => return Err(e.display())
  }
  Ok(r)
}

///|
test "metadata-resolve/passing: V3 メタデータを互換ローダが受理できる" {
  let dirs = v3_case_dirs("fixtures/metadata-resolve/passing")
  let failures : Array[String] = []
  for dir in dirs {
    match try_load_v3(dir) {
      Ok(_) => ()
      Err(msg) => failures.push("\{dir}: \{msg}")
    }
  }
  println(
    "v3 passing: \{dirs.length() - failures.length()}/\{dirs.length()} accepted",
  )
  for f in failures {
    println("  REJECTED \{f}")
  }
  if failures.length() > 0 {
    fail("\{failures.length()} passing cases were rejected")
  }
}

///|
/// Mosura の検証 (参照整合性・重複名・source 必須) が拒否できる failing ケース。
/// 残りは V3 固有の検証範囲 (BooleanExpressionType / aggregate / command 等) のため
/// 台帳 (fixtures/cases.toml) で pending 管理する
let v3_failing_rejected : Array[String] = [
  "fixtures/metadata-resolve/failing/aggregate_expression_in_relationship/missing_model_source",
  "fixtures/metadata-resolve/failing/aggregate_expressions/missing_model_source",
  "fixtures/metadata-resolve/failing/model_permissions/missing_model_source", "fixtures/metadata-resolve/failing/models/duplicate_argument",
  "fixtures/metadata-resolve/failing/models/duplicate_graphql_root_fields", "fixtures/metadata-resolve/failing/models/missing_object_type",
  "fixtures/metadata-resolve/failing/models/two_missing_object_types", "fixtures/metadata-resolve/failing/order_by_expressions/array_relationship",
  "fixtures/metadata-resolve/failing/order_by_expressions/disallow_relationship_to_sourceless_model",
  "fixtures/metadata-resolve/failing/order_by_expressions/model_type_mismatch", "fixtures/metadata-resolve/failing/order_by_expressions/unknown_field",
  "fixtures/metadata-resolve/failing/order_by_expressions/unknown_order_by_expression_in_model",
  "fixtures/metadata-resolve/failing/remote_relationships_permissions/across_subgraphs",
  "fixtures/metadata-resolve/failing/simple", "fixtures/metadata-resolve/failing/scalar_types/cannot_match_inbuilt_type_name",
  "fixtures/metadata-resolve/failing/scalar_types/multiple_errors", "fixtures/metadata-resolve/failing/boolean_expression/object_comparable_field_duplicated",
  // aggregate expression の接続非依存検証で拒否できるようになったケース
   "fixtures/metadata-resolve/failing/aggregate_expressions/aggregatable_field_not_found",
  "fixtures/metadata-resolve/failing/aggregate_expressions/conflict_between_count_and_aggregatable_field",
  "fixtures/metadata-resolve/failing/aggregate_expressions/conflict_between_count_and_aggregation_function",
  "fixtures/metadata-resolve/failing/aggregate_expressions/conflict_between_count_distinct_and_aggregatable_field",
  "fixtures/metadata-resolve/failing/aggregate_expressions/conflict_between_count_distinct_and_aggregation_function",
  "fixtures/metadata-resolve/failing/aggregate_expressions/count_distinct_return_type_cannot_use_non_int_inbuilt",
  "fixtures/metadata-resolve/failing/aggregate_expressions/count_return_type_cannot_use_non_int_inbuilt",
  "fixtures/metadata-resolve/failing/aggregate_expressions/disallow_duplicate_name",
  "fixtures/metadata-resolve/failing/aggregate_expressions/duplicated_aggregatable_fields",
  "fixtures/metadata-resolve/failing/aggregate_expressions/duplicated_aggregation_functions",
  "fixtures/metadata-resolve/failing/aggregate_expressions/missing_aggregate_exp_from_model",
  "fixtures/metadata-resolve/failing/aggregate_expressions/missing_operand_object_field_agg_exp",
  "fixtures/metadata-resolve/failing/aggregate_expressions/missing_operand_object_type",
  "fixtures/metadata-resolve/failing/aggregate_expressions/model_aggregate_exp_type_mismatch",
  // DataConnectorLink の NDC capabilities バージョン検証で拒否できるケース。
  // incompatible_capabilities_for_local_relationship はバージョン整合ではなく
  // リレーション capability の内容検証 (後段) が必要なため pending のまま。
   "fixtures/metadata-resolve/failing/data_connector_link/incompatible_capabilities_version",
  "fixtures/metadata-resolve/failing/data_connector_link/invalid_ndc_v01_capabilities_version_failing_with_error",
  "fixtures/metadata-resolve/failing/data_connector_link/multiple_errors",
]

///|
test "metadata-resolve/failing: Mosura の検証で拒否できるケースの回帰固定" {
  let dirs = v3_case_dirs("fixtures/metadata-resolve/failing")
  let rejected : Array[String] = []
  for dir in dirs {
    match try_load_v3(dir) {
      Ok(_) => ()
      Err(_) => rejected.push(dir)
    }
  }
  println(
    "v3 failing: \{rejected.length()}/\{dirs.length()} rejected by mosura validations",
  )
  // 拒否できる集合が変わったら意図的な変更かを確認して更新する (集合として比較)
  assert_eq(rejected.length(), v3_failing_rejected.length())
  for r in rejected {
    assert_true(v3_failing_rejected.contains(r))
  }
}
