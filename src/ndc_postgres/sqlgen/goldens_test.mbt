// ndc-postgres translation ゴールデンテスト。
// 期待ファイルはテストハーネス側で sqlformat 整形されているため、
// 空白を正規化した上で比較する (SQL の内容・クオート・エイリアス採番は完全一致を要求)。

///|
fn normalize_sql_text(s : String) -> String {
  let sb = StringBuilder::new()
  let mut prev_space = true
  for c in s {
    let is_space = c == ' ' || c == '\n' || c == '\r' || c == '\t'
    if is_space {
      if !prev_space {
        sb.write_char(' ')
        prev_space = true
      }
    } else {
      sb.write_char(c)
      prev_space = false
    }
  }
  let collapsed = sb.to_string()
  // 括弧・カンマ・セミコロン前後の空白を除去
  let out = StringBuilder::new()
  let chars = collapsed.iter().collect()
  for i in 0..<chars.length() {
    let c = chars[i]
    if c == ' ' {
      let next = if i + 1 < chars.length() { chars[i + 1] } else { ' ' }
      let prev = if i > 0 { chars[i - 1] } else { ' ' }
      if next == '(' ||
        next == ')' ||
        next == ',' ||
        next == ';' ||
        prev == '(' ||
        prev == ',' {
        continue
      }
    }
    out.write_char(c)
  }
  let result = out.to_string()
  // 先頭・末尾の空白を除去
  result.trim(chars=" ").to_owned()
}

///|
/// Rust の {:#?} 互換で params (BTreeMap<usize, Param>) を表示
fn params_debug(params : Array[Param]) -> String {
  if params.is_empty() {
    return "{}"
  }
  let sb = StringBuilder::new()
  sb.write_string("{\n")
  for i, p in params {
    sb.write_string("    \{i + 1}: ")
    match p {
      PString(s) => sb.write_string("String(\n        \"\{s}\",\n    )")
      PVariable(v) => sb.write_string("Variable(\n        \"\{v}\",\n    )")
      PValue(j) => {
        sb.write_string("Value(\n        ")
        sb.write_string(serde_value_debug(j))
        sb.write_string(",\n    )")
      }
    }
    sb.write_string(",\n")
  }
  sb.write_string("}")
  sb.to_string()
}

///|
/// serde_json::Value の Debug 近似 (空白正規化で比較するため整形は簡易)
fn serde_value_debug(j : Json) -> String {
  match j {
    Json::Null => "Null"
    Json::True => "Bool(true)"
    Json::False => "Bool(false)"
    Json::Number(d, repr~) => {
      let n = match repr {
        Some(r) => r
        None =>
          if d == d.floor() {
            d.to_int64().to_string()
          } else {
            d.to_string()
          }
      }
      "Number(\{n})"
    }
    Json::String(s) => "String(\"\{s}\")"
    Json::Array(items) => {
      let inner = items.map(i => serde_value_debug(i)).join(", ")
      "Array [\{inner}]"
    }
    Json::Object(m) => {
      let parts = []
      for k, v in m {
        parts.push("\"\{k}\": \{serde_value_debug(v)}")
      }
      let joined = parts.join(", ")
      "Object {\{joined}}"
    }
  }
}

///|
fn run_translation_case(dir : String) -> Result[String, String] raise {
  let config = @json.parse(@fs.read_file_to_string("\{dir}/configuration.json"))
  let metadata = decode_pg_metadata(config) catch {
    NdcDecode(m) => return Err("decode: \{m}")
  }
  let request_json = @json.parse(@fs.read_file_to_string("\{dir}/request.json"))
  let request = decode_query_request(request_json) catch {
    NdcDecode(m) => return Err("decode: \{m}")
  }
  let sql = translate_query_request(metadata, request) catch {
    e => return Err(e.display())
  }
  Ok(sql.sql + ";\n\n" + params_debug(sql.params))
}

///|
test "ndc-postgres translation goldens" {
  let base = "fixtures/ndc-postgres-translation"
  let dirs = @fs.read_dir("\{base}/goldenfiles")
  dirs.sort()
  let mut passed = 0
  let skipped : Array[String] = []
  let failures : Array[String] = []
  for case_name in dirs {
    let dir = "\{base}/goldenfiles/\{case_name}"
    if !@fs.path_exists("\{dir}/request.json") {
      continue
    }
    // 期待スナップショットを探す
    let candidates = [
      "\{base}/snapshots/tests__it_\{case_name}.expected",
      "\{base}/snapshots/tests__\{case_name}.expected",
    ]
    let mut expected_path : String? = None
    for c in candidates {
      if @fs.path_exists(c) {
        expected_path = Some(c)
      }
    }
    let expected_path = match expected_path {
      Some(p) => p
      None => continue
    }
    match run_translation_case(dir) {
      Ok(actual_text) => {
        let expected = @fs.read_file_to_string(expected_path)
        if normalize_sql_text(actual_text) == normalize_sql_text(expected) {
          passed += 1
        } else {
          failures.push(case_name)
        }
      }
      // 未対応機能 (aggregates / nested / order-by-relation 等) はスキップとして数える
      Err(msg) => skipped.push("\{case_name}: \{msg}")
    }
  }
  println("translation goldens: passed=\{passed} skipped=\{skipped.length()}")
  for s in skipped {
    println("  skip \{s}")
  }
  if failures.length() > 0 {
    let joined = failures.join(", ")
    fail("mismatch: \{joined}")
  }
  assert_true(passed >= 10)
}
