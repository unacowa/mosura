// lang-graphql/src/lexer/number.rs の移植
// 数値の部分パースは lexical_core::parse_partial の GraphQL で到達しうる範囲を再現する

///|
pub(all) enum NumberToken {
  Float64(Double)
  Int64(Int64)
} derive(Eq)

///|
pub(all) enum NumberError {
  DigitExpected(Byte?)
  // lexical_core::Error 相当。デバッグ表示用のメッセージのみ保持する
  LexicalError(String)
  NameStart(Byte)
} derive(Eq)

///|
fn is_digit(b : Byte) -> Bool {
  b >= b'0' && b <= b'9'
}

///|
/// bytes[offset..] から数値をパースし (トークン, 消費バイト数) を返す
pub fn parse_lexer_number(
  bytes : Bytes,
  offset : Int,
) -> Result[(NumberToken, Int), NumberError] {
  let len = bytes.length()
  let mut ix = offset
  // 負号
  if ix < len && bytes[ix] == b'-' {
    ix += 1
  }
  // 整数部の桁数 (整数と浮動小数点の区別に使う)
  let mut integer_count = 0
  while ix + integer_count < len && is_digit(bytes[ix + integer_count]) {
    integer_count += 1
  }
  if integer_count == 0 {
    let found = if ix < len { Some(bytes[ix]) } else { None }
    return Err(DigitExpected(found))
  }
  let after_int = ix + integer_count
  let parse_as_integer = if after_int < len {
    let c = bytes[after_int]
    !(c == b'.' || c == b'e' || c == b'E')
  } else {
    true
  }
  let parsed : Result[(NumberToken, Int), NumberError] = if parse_as_integer {
    let text = ascii_slice(bytes, offset, after_int)
    try {
      let v = @string.parse_int64(text)
      Ok((Int64(v), after_int - offset))
    } catch {
      // i64 範囲外。lexical_core の Overflow/Underflow 相当
      _ =>
        Err(
          LexicalError(
            if bytes[offset] == b'-' {
              "Underflow"
            } else {
              "Overflow"
            },
          ),
        )
    }
  } else {
    // 浮動小数点: [sign] digits [. digits*] [(e|E) [sign] digits+]
    let mut end = after_int
    if end < len && bytes[end] == b'.' {
      end += 1
      while end < len && is_digit(bytes[end]) {
        end += 1
      }
    }
    if end < len && (bytes[end] == b'e' || bytes[end] == b'E') {
      let mut exp_end = end + 1
      if exp_end < len && (bytes[exp_end] == b'+' || bytes[exp_end] == b'-') {
        exp_end += 1
      }
      let digits_start = exp_end
      while exp_end < len && is_digit(bytes[exp_end]) {
        exp_end += 1
      }
      if exp_end > digits_start {
        end = exp_end
      } else {
        // 指数部が空 (lexical_core: EmptyExponent)
        return Err(LexicalError("EmptyExponent"))
      }
    }
    let text = ascii_slice(bytes, offset, end)
    try {
      let v = @string.parse_double(text)
      Ok((Float64(v), end - offset))
    } catch {
      _ => Err(LexicalError("InvalidFloat"))
    }
  }
  match parsed {
    Ok((token, consumed)) => {
      let look_ix = offset + consumed
      if look_ix < len {
        let look_ahead = bytes[look_ix]
        if (look_ahead >= b'a' && look_ahead <= b'z') ||
          (look_ahead >= b'A' && look_ahead <= b'Z') {
          Err(NameStart(look_ahead))
        } else {
          Ok((token, consumed))
        }
      } else {
        Ok((token, consumed))
      }
    }
    Err(e) => Err(e)
  }
}

///|
/// ASCII 前提のバイト範囲を String へ (数値リテラル用)
fn ascii_slice(bytes : Bytes, start : Int, end : Int) -> String {
  let sb = StringBuilder::new()
  for i in start..<end {
    sb.write_char(bytes[i].to_char())
  }
  sb.to_string()
}
