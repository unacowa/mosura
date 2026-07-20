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
/// fixtures/cases.toml から in-scope の translation ケース名を読む (簡易パーサ)。
/// in-scope タグのケースが skip されたら CI が落ちるようにするための突き合わせ
fn in_scope_translation_cases() -> Array[String] raise {
  let prefix = "ndc-postgres-translation/goldenfiles/"
  let text = @fs.read_file_to_string("fixtures/cases.toml")
  let out : Array[String] = []
  let mut current : String? = None
  for line in text.split("\n") {
    let l = line.to_owned().trim(chars=" \r").to_owned()
    if l.has_prefix("[cases.\"") && l.has_suffix("\"]") {
      current = Some(l["[cases.\"".length():l.length() - 2].to_owned())
    } else if l == "tag = \"in-scope\"" {
      match current {
        Some(id) =>
          if id.has_prefix(prefix) {
            out.push(id[prefix.length():].to_owned())
          }
        None => ()
      }
    }
  }
  out
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
/// goldenfiles 以下を再帰的に走査し、request.json を持つケースの相対パスを返す
fn list_translation_cases(base : String) -> Array[String] raise {
  let out : Array[String] = []
  fn walk(rel : String) -> Unit raise {
    let dir = if rel == "" {
      "\{base}/goldenfiles"
    } else {
      "\{base}/goldenfiles/\{rel}"
    }
    if @fs.path_exists("\{dir}/request.json") {
      out.push(rel)
    }
    let entries = @fs.read_dir(dir)
    entries.sort()
    for e in entries {
      let child = if rel == "" { e } else { "\{rel}/\{e}" }
      if @fs.is_dir("\{dir}/\{e}") {
        walk(child)
      }
    }
  }

  walk("")
  out
}

///|
/// ケース (相対パス) に対応する期待スナップショットを解決する。
/// スナップショット名は upstream の Rust テスト関数名由来で揺れがあり
/// (tests__it_ / tests__ / tests__it_converts_ / tests__<module>__ 等)、
/// また case ディレクトリに co-located の場合と snapshots/ に集約の場合がある。
/// まず厳密候補を、無ければ末尾セグメント名で "..._<leaf>.expected" に
/// 一意一致するファイルを case ディレクトリ → snapshots/ の順に探す。
fn resolve_snapshot(base : String, rel : String) -> String? raise {
  let segs = rel.split("/").collect()
  let leaf = segs[segs.length() - 1].to_owned()
  let case_dir = "\{base}/goldenfiles/\{rel}"
  let snap_dir = "\{base}/snapshots"
  for
    c in [
      "\{snap_dir}/tests__it_\{leaf}.expected",
      "\{snap_dir}/tests__\{leaf}.expected",
    ] {
    if @fs.path_exists(c) {
      return Some(c)
    }
  }
  let suffix = "\{leaf}.expected"
  for d in [case_dir, snap_dir] {
    let mut found : String? = None
    let mut count = 0
    for f in @fs.read_dir(d) {
      if f == suffix || f.has_suffix("_\{suffix}") {
        found = Some("\{d}/\{f}")
        count += 1
      }
    }
    if count == 1 {
      return found
    }
  }
  None
}

///|
test "ndc-postgres translation goldens" {
  let base = "fixtures/ndc-postgres-translation"
  let in_scope = in_scope_translation_cases()
  let mut passed = 0
  let passed_names : Array[String] = []
  let skipped : Array[String] = []
  // in-scope の不一致のみ CI を落とす。in-scope 外の不一致 (Mosura が独自 SQL を
  // 出す mutations 等、台帳で out-of-scope のもの) は情報として出すだけにする
  let failures : Array[String] = []
  let diffs_non_scope : Array[String] = []
  for rel in list_translation_cases(base) {
    let dir = "\{base}/goldenfiles/\{rel}"
    let expected_path = match resolve_snapshot(base, rel) {
      Some(p) => p
      None => continue
    }
    match run_translation_case(dir) {
      Ok(actual_text) => {
        let expected = @fs.read_file_to_string(expected_path)
        if normalize_sql_text(actual_text) == normalize_sql_text(expected) {
          passed += 1
          passed_names.push(rel)
        } else if in_scope.contains(rel) {
          failures.push(rel)
        } else {
          diffs_non_scope.push(rel)
        }
      }
      // 未対応機能 (aggregates / nested / order-by-relation 等) はスキップとして数える
      Err(msg) => skipped.push("\{rel}: \{msg}")
    }
  }
  println(
    "translation goldens: passed=\{passed} skipped=\{skipped.length()} diff(non-scope)=\{diffs_non_scope.length()}",
  )
  for s in skipped {
    println("  skip \{s}")
  }
  for d in diffs_non_scope {
    println("  diff(non-scope) \{d}")
  }
  if failures.length() > 0 {
    let joined = failures.join(", ")
    fail("in-scope mismatch: \{joined}")
  }
  // cases.toml との突き合わせ: in-scope タグのケースは必ずスナップショット照合を
  // 通過していること (raise → skip やスナップショット欠如で黙ってグリーンにしない)
  let not_green : Array[String] = []
  for name in in_scope_translation_cases() {
    if !passed_names.contains(name) {
      not_green.push(name)
    }
  }
  if not_green.length() > 0 {
    let joined = not_green.join(", ")
    fail("in-scope cases did not pass snapshot comparison: \{joined}")
  }
  assert_true(passed >= 10)
}
