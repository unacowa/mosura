// SDL パーサのゴールデン/スモークテスト
// - testdata/*.graphql + .ast.txt: parse_schema_document の AST がゴールデンと一致
// - schema_testdata/ok: パース成功必須 / schema_testdata/err: パース失敗必須 (期待値ファイルなし)

///|
test "schema parser golden: testdata (star_wars 等)" {
  let dir = "fixtures/lang-graphql/testdata"
  let files = @fs.read_dir(dir)
  files.sort()
  let mut total = 0
  for f in files {
    if !f.has_suffix(".graphql") {
      continue
    }
    let base = f[0:f.length() - 8].to_owned()
    let expected_path = "\{dir}/\{base}.ast.txt"
    if !@fs.path_exists(expected_path) {
      continue
    }
    total += 1
    let input = @fs.read_file_to_bytes("\{dir}/\{base}.graphql")
    let parser = Parser::new(input)
    let doc = parser.parse_schema_document() catch {
      ParseErr(_) => {
        fail("\{base}: expected Ok but parse failed")
        return
      }
    }
    let actual = debug_schema_document(doc)
    let expected = @fs.read_file_to_string(expected_path)
    if actual != expected {
      fail("\{base}: AST mismatch")
    }
  }
  println("schema golden: \{total} cases passed")
  assert_true(total >= 1)
}

///| 移植元 lang-graphql のパーサが対応していない構文 (type extension / directive definition)。

///|
/// apollo-rs 由来のテストデータだが移植元でもパース不能のため out-of-scope (cases.toml 参照)
let schema_ok_unsupported : Array[String] = [
  "0007_directive_definition.graphql", "0008_directive_definition_with_arguments.graphql",
  "0009_directive_definition_repeatable.graphql", "0011_enum_type_extension.graphql",
  "0015_input_extension.graphql", "0017_interface_extension.graphql", "0019_object_type_extension.graphql",
  "0024_scalar_extension.graphql", "0026_schema_extension.graphql", "0029_union_type_extension.graphql",
  "0032_supergraph.graphql",
]

///|
fn schema_smoke(subdir : String, expect_ok : Bool) -> Unit raise {
  let dir = "fixtures/lang-graphql/schema_testdata/\{subdir}"
  let files = @fs.read_dir(dir)
  files.sort()
  let failures : Array[String] = []
  let mut total = 0
  for f in files {
    if !f.has_suffix(".graphql") {
      continue
    }
    if subdir == "ok" && schema_ok_unsupported.contains(f) {
      continue
    }
    total += 1
    let input = @fs.read_file_to_bytes("\{dir}/\{f}")
    let parser = Parser::new(input)
    let ok = try {
      ignore(parser.parse_schema_document())
      true
    } catch {
      ParseErr(_) => false
    }
    if ok != expect_ok {
      failures.push(f)
    }
  }
  if failures.length() > 0 {
    fail(
      "\{failures.length()}/\{total} cases failed in schema_testdata/\{subdir}: \{failures.join(", ")}",
    )
  }
  println("schema smoke \{subdir}: \{total} cases passed")
}

///|
test "schema parser smoke: schema_testdata/ok" {
  schema_smoke("ok", true)
}

///|
test "schema parser smoke: schema_testdata/err" {
  schema_smoke("err", false)
}
