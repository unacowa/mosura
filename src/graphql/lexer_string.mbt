// lang-graphql/src/lexer/string.rs の移植

///|
/// 文字列リテラルの字句解析エラー
pub(all) enum StringError {
  StartingSequenceNotFound(Byte?)
  Unterminated
  UnknownCharacterInString(Char)
  UnknownEscapeSequence(String)
  InvalidUnicodeEscapeSequence(String)
} derive(Eq)

///|
/// 字句解析で消費した行数・文字数
pub(all) struct Consumed {
  mut line_breaks : Int
  mut chars_without_further_line_break : Int
}

///|
fn Consumed::no_line_break(chars : Int) -> Consumed {
  { line_breaks: 0, chars_without_further_line_break: chars }
}

///|
fn Consumed::count_line_break(self : Consumed) -> Unit {
  self.line_breaks += 1
  self.chars_without_further_line_break = 0
}

///|
fn Consumed::count_chars(self : Consumed, chars : Int) -> Unit {
  self.chars_without_further_line_break += chars
}

///|
/// UTF-8 先頭バイトからその文字のバイト数を得る
fn num_bytes_in_char(first_byte : Byte) -> Int {
  if first_byte <= 0x7F {
    1
  } else if first_byte <= 0b1101_1111 {
    2
  } else if first_byte <= 0b1110_1111 {
    3
  } else {
    4
  }
}

///|
fn is_ws(b : Byte) -> Bool {
  b == b' ' || b == b'\t'
}

///|
fn utf8_slice(bytes : Bytes, start : Int, end : Int) -> String {
  @utf8.decode_lossy(bytes[start:end])
}

///|
/// ブロック文字列内の 1 行 (バイト範囲 + `\"""` エスケープの位置)
priv struct Line {
  mut start : Int
  mut end : Int
  escape_chars : Array[Int]
}

///|
fn Line::new(start : Int) -> Line {
  { start, end: start, escape_chars: [] }
}

///|
fn Line::len(self : Line) -> Int {
  self.end - self.start
}

///|
fn Line::trim_front(self : Line, count : Int) -> Unit {
  let next = self.start + count
  self.start = if next < self.end { next } else { self.end }
}

///|
/// 行内が全て空白 (インデント計測用)
fn Line::indent_of(self : Line, bytes : Bytes) -> Int {
  let mut n = 0
  for i in self.start..<self.end {
    if is_ws(bytes[i]) {
      n += 1
    } else {
      break
    }
  }
  n
}

///|
fn Line::all_whitespace(self : Line, bytes : Bytes) -> Bool {
  for i in self.start..<self.end {
    if !is_ws(bytes[i]) {
      return false
    }
  }
  true
}

///|
fn Line::append_to(self : Line, bytes : Bytes, s : StringBuilder) -> Unit {
  let mut i = self.start
  for escape_char_i in self.escape_chars {
    s.write_string(utf8_slice(bytes, i, escape_char_i))
    i = escape_char_i + 1
  }
  s.write_string(utf8_slice(bytes, i, self.end))
}

///|
/// ブロック文字列 https://spec.graphql.org/October2021/#sec-String-Value.Block-Strings
fn parse_block_string(
  bytes : Bytes,
  offset : Int,
) -> Result[(String, Consumed, Int), (StringError, Consumed)] {
  let len = bytes.length()
  if !(offset + 2 < len &&
    bytes[offset] == b'"' &&
    bytes[offset + 1] == b'"' &&
    bytes[offset + 2] == b'"') {
    let first = if offset < len { Some(bytes[offset]) } else { None }
    return Err((StartingSequenceNotFound(first), Consumed::no_line_break(0)))
  }
  let lines : Array[Line] = []
  let mut i = offset + 3
  let consumed = Consumed::no_line_break(3)
  let mut cur_line = Line::new(i)
  let mut terminated = false
  while i < len {
    let b = bytes[i]
    if b == b'"' && i + 2 < len && bytes[i + 1] == b'"' && bytes[i + 2] == b'"' {
      cur_line.end = i
      lines.push(cur_line)
      consumed.count_chars(3)
      i += 3
      terminated = true
      break
    } else if b == b'\\' &&
      i + 3 < len &&
      bytes[i + 1] == b'"' &&
      bytes[i + 2] == b'"' &&
      bytes[i + 3] == b'"' {
      cur_line.escape_chars.push(i)
      consumed.count_chars(4)
      i += 4
    } else if b == b'\r' && i + 1 < len && bytes[i + 1] == b'\n' {
      cur_line.end = i
      lines.push(cur_line)
      consumed.count_line_break()
      i += 2
      cur_line = Line::new(i)
    } else if b == b'\n' || b == b'\r' {
      cur_line.end = i
      lines.push(cur_line)
      consumed.count_line_break()
      i += 1
      cur_line = Line::new(i)
    } else {
      consumed.count_chars(1)
      i += num_bytes_in_char(b)
    }
  }
  if !terminated {
    return Err((Unterminated, consumed))
  }

  // 共通インデントの算出 (先頭行は除外、空白のみの行は除外)
  let mut common_indent : Int? = None
  for li in 1..<lines.length() {
    let line = lines[li]
    let indent = line.indent_of(bytes)
    if indent < line.len() {
      common_indent = match common_indent {
        None => Some(indent)
        Some(m) => Some(if indent < m { indent } else { m })
      }
    }
  }
  match common_indent {
    Some(ci) =>
      for li in 1..<lines.length() {
        lines[li].trim_front(ci)
      }
    None => ()
  }

  // 先頭・末尾の空白のみ行を除外
  let mut empty_front = 0
  while empty_front < lines.length() && lines[empty_front].all_whitespace(bytes) {
    empty_front += 1
  }
  let mut empty_back = 0
  while empty_back < lines.length() - empty_front &&
        lines[lines.length() - 1 - empty_back].all_whitespace(bytes) {
    empty_back += 1
  }
  let result = StringBuilder::new()
  let mut line_index = 0
  for li in empty_front..<(lines.length() - empty_back) {
    if line_index > 0 {
      result.write_char('\n')
    }
    lines[li].append_to(bytes, result)
    line_index += 1
  }
  Ok((result.to_string(), consumed, i - offset))
}

///|
fn hex_digit_value(b : Byte) -> Int? {
  if b >= b'0' && b <= b'9' {
    Some((b - b'0').to_int())
  } else if b >= b'a' && b <= b'f' {
    Some((b - b'a').to_int() + 10)
  } else if b >= b'A' && b <= b'F' {
    Some((b - b'A').to_int() + 10)
  } else {
    None
  }
}

///|
/// 単一行文字列 https://spec.graphql.org/October2021/#StringValue
fn parse_single_line_string(
  bytes : Bytes,
  offset : Int,
) -> Result[(String, Consumed, Int), (StringError, Consumed)] {
  let len = bytes.length()
  let result = StringBuilder::new()
  // Unicode スカラー値の個数
  let mut chars = 1
  let mut mark = offset + 1
  let mut end_reached = false
  let mut i = offset + 1
  while i < len {
    let b = bytes[i]
    if b == b'\\' {
      if i + 1 >= len {
        return Err((Unterminated, Consumed::no_line_break(chars)))
      }
      let next = bytes[i + 1]
      let mut unescaped : Char = ' '
      let mut bytes_consumed = 1
      if next == b'"' {
        unescaped = '\u{0022}'
      } else if next == b'\\' {
        unescaped = '\u{005C}'
      } else if next == b'/' {
        unescaped = '\u{002F}'
      } else if next == b'b' {
        unescaped = '\u{0008}'
      } else if next == b'f' {
        unescaped = '\u{000C}'
      } else if next == b'n' {
        unescaped = '\u{000A}'
      } else if next == b'r' {
        unescaped = '\u{000D}'
      } else if next == b't' {
        unescaped = '\u{0009}'
      } else if next == b'u' {
        if i + 5 >= len {
          return Err((Unterminated, Consumed::no_line_break(chars)))
        }
        let mut code_point = 0
        let mut valid_hex = true
        for k in 0..<4 {
          match hex_digit_value(bytes[i + 2 + k]) {
            Some(v) => code_point = code_point * 16 + v
            None => valid_hex = false
          }
        }
        if !valid_hex {
          return Err(
            (
              InvalidUnicodeEscapeSequence("invalid hex digits"),
              Consumed::no_line_break(chars),
            ),
          )
        }
        // サロゲート領域と範囲外は不正なコードポイント
        if (code_point >= 0xD800 && code_point <= 0xDFFF) ||
          code_point > 0x10FFFF {
          let hex = to_hex_upper(code_point)
          return Err(
            (
              InvalidUnicodeEscapeSequence("0x\{hex} is not a valid code point"),
              Consumed::no_line_break(chars),
            ),
          )
        }
        unescaped = code_point.unsafe_to_char()
        bytes_consumed = 5
      } else {
        return Err(
          (
            UnknownEscapeSequence("\\\{next.to_int()}"),
            Consumed::no_line_break(chars),
          ),
        )
      }
      result.write_string(utf8_slice(bytes, mark, i))
      result.write_char(unescaped)
      mark = i + bytes_consumed + 1
      i += bytes_consumed + 1
      chars += bytes_consumed + 1
    } else if b == b'"' {
      end_reached = true
      chars += 1
      i += 1
      break
    } else if b == b'\n' || b == b'\r' {
      return Err((Unterminated, Consumed::no_line_break(chars)))
    } else {
      i += num_bytes_in_char(b)
      chars += 1
    }
  }
  if !end_reached {
    Err((Unterminated, Consumed::no_line_break(chars)))
  } else if mark == offset + 1 {
    Ok(
      (
        utf8_slice(bytes, offset + 1, i - 1),
        Consumed::no_line_break(chars),
        i - offset,
      ),
    )
  } else {
    result.write_string(utf8_slice(bytes, mark, i - 1))
    Ok((result.to_string(), Consumed::no_line_break(chars), i - offset))
  }
}

///|
fn to_hex_upper(n : Int) -> String {
  let digits : Array[Char] = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F',
  ]
  if n == 0 {
    return "0"
  }
  let sb = StringBuilder::new()
  let mut v = n
  let parts : Array[Char] = []
  while v > 0 {
    parts.push(digits[v % 16])
    v = v / 16
  }
  parts.rev_each(c => sb.write_char(c))
  sb.to_string()
}

///|
/// 文字列リテラルのパース (通常/ブロック共通の入口)
pub fn parse_lexer_string(
  bytes : Bytes,
  offset : Int,
) -> Result[(String, Consumed, Int), (StringError, Consumed)] {
  let len = bytes.length()
  if offset + 2 < len &&
    bytes[offset] == b'"' &&
    bytes[offset + 1] == b'"' &&
    bytes[offset + 2] == b'"' {
    parse_block_string(bytes, offset)
  } else if offset < len && bytes[offset] == b'"' {
    parse_single_line_string(bytes, offset)
  } else {
    let first = if offset < len { Some(bytes[offset]) } else { None }
    Err((StartingSequenceNotFound(first), Consumed::no_line_break(0)))
  }
}
