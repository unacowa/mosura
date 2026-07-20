// execute フィクスチャで合格を固定したケースの一覧。
// V3 の期待レスポンスと構造一致することを確認済み (回帰として維持する)。
// 新たに通るようになったケースはテスト出力の NEW-PASS を確認して追加すること。
//
// 意図的に pin しないケース (NEW-PASS に出るが追加しないこと):
// - models/select_many/where/remote_relationships/.../simple_across_subgraphs
//   → 真のクロスコネクタ (remote) リレーション。合格するのは auto_stub_connectors
//     が remote_db を同一 PG にスタブするテストアーティファクトのためで、
//     remote relationships (対象外) を実装したわけではない

///|
pub fn execute_passing_cases_list() -> Array[String] {
  [
    "models/select_many/permission_filter/simple", "models/select_many/simple_select",
    "models/select_many/simple_select/filter", "models/select_many/where/filter",
    "models/select_many/where/is_null/boolean_expression_type", "models/select_many/where/is_null/object_boolean_expression_type",
    "models/select_many/where/multiple_fields", "models/select_many/where/ndc_operators",
    "models/select_many/where/shared_boolean_expression", "models/select_one/simple_select",
    "models/select_one/simple_select/filter", "plugins/pre_ndc_request/pass_through",
    "plugins/pre_ndc_response/pass_through", "plugins/pre_parse/pass_through", "relationships/across_namespace",
    "relationships/array", "relationships/multi_mapping", "relationships/no_relationship_capability",
    "relationships/object", "relationships/same_relationship_name", "remote_relationships/array",
    "session_variables/json_disabled/integer_session_variable", "session_variables/json_enabled/integer_session_variable",
    "variables/non_null_type_default_value",
  ]
}
