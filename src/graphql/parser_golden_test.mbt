// lang-graphql のパーサゴールデンテスト (fixtures/lang-graphql/query_testdata)
// ok/ は Ok + AST 一致、err/ は Err + エラー表示一致を要求する (移植元の parser_test.rs 相当)

///|
fn fixture_dir() -> String {
  "fixtures/lang-graphql/query_testdata"
}

///|
fn golden_dir_test(subdir : String, expect_ok : Bool) -> Unit raise {
  let dir = "\{fixture_dir()}/\{subdir}"
  let files = @fs.read_dir(dir)
  files.sort()
  let failures : Array[String] = []
  let mut total = 0
  for f in files {
    if !f.has_suffix(".graphql") {
      continue
    }
    let base = f[0:f.length() - 8].to_owned()
    total += 1
    let input = @fs.read_file_to_bytes("\{dir}/\{base}.graphql")
    let parser = Parser::new(input)
    let result : Result[ExecutableDocument, Positioned[ParseError]] = Ok(
      parser.parse_executable_document(),
    ) catch {
      ParseErr(p) => Err(p)
    }
    // ok/ は成功必須、err/ は失敗必須
    match (expect_ok, result) {
      (true, Err(_)) => {
        failures.push("\{base}: expected Ok but got Err")
        continue
      }
      (false, Ok(_)) => {
        failures.push("\{base}: expected Err but got Ok")
        continue
      }
      _ => ()
    }
    let expected = @fs.read_file_to_string("\{dir}/\{base}.txt")
    let actual = debug_parse_result(result)
    if actual != expected {
      failures.push("\{base}: output mismatch")
    }
  }
  if failures.length() > 0 {
    let msg = failures.join("\n")
    fail("\{failures.length()}/\{total} cases failed in \{subdir}:\n\{msg}")
  }
  println("golden \{subdir}: \{total} cases passed")
}

///|
test "parser golden: query_testdata/ok" {
  golden_dir_test("ok", true)
}

///|
test "parser golden: query_testdata/err" {
  golden_dir_test("err", false)
}
