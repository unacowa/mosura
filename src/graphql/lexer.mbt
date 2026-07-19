// lang-graphql/src/lexer.rs の移植

///|
pub(all) enum Punctuation {
  Bang
  Dollar
  Amp
  ParenL
  ParenR
  Spread
  Colon
  Equals
  At
  BracketL
  BracketR
  BraceL
  Pipe
  BraceR
} derive(Eq)

///|
pub fn Punctuation::as_str(self : Punctuation) -> String {
  match self {
    Bang => "!"
    Dollar => "$"
    Amp => "&"
    ParenL => "("
    ParenR => ")"
    Spread => "..."
    Colon => ":"
    Equals => "="
    At => "@"
    BracketL => "["
    BracketR => "]"
    BraceL => "{"
    BraceR => "}"
    Pipe => "|"
  }
}

///|
pub(all) enum Token {
  Punctuation(Punctuation)
  Name(Name)
  Number(NumberToken)
  TString(String)
} derive(Eq)

///|
pub fn Token::display(self : Token) -> String {
  match self {
    Punctuation(p) => "Punctuation(\{p.as_str()})"
    Name(name) => "Name(\{name.as_str()})"
    Number(Float64(f)) => "Number(\{rust_f64_display(f)})"
    Number(Int64(i)) => "Number(\{i})"
    TString(str) => "String(\{str})"
  }
}

///|
/// 字句解析エラー
pub(all) enum LexerError {
  UnexpectedCharacter(Char)
  UnexpectedEndOfFile
  InvalidString(StringError)
  InvalidNumber(NumberError)
  InvalidGraphQlName(String)
} derive(Eq)

///|
pub type LexResult = Result[Spanning[Token], Positioned[LexerError]]

///|
pub(all) struct Lexer {
  bytes : Bytes
  mut ix : Int
  mut line : Int
  mut column : Int
}

///|
pub fn Lexer::new(source : Bytes) -> Lexer {
  { bytes: source, ix: 0, line: 1, column: 1 }
}

///|
pub fn Lexer::get_position(self : Lexer) -> SourcePosition {
  SourcePosition::new(self.line, self.column)
}

///|
fn Lexer::seek_lines(self : Lexer, count : Int) -> Unit {
  if count > 0 {
    self.line += count
    self.column = 1
  }
}

///|
fn Lexer::seek_column_by(self : Lexer, count : Int) -> Unit {
  self.column += count
}

///|
fn Lexer::seek(self : Lexer, lines : Int, columns : Int) -> Unit {
  self.seek_lines(lines)
  self.seek_column_by(columns)
}

///|
fn Lexer::consume_punctuation_token(
  self : Lexer,
  t : Punctuation,
) -> Spanning[Token] {
  let token_position = SourcePosition::new(self.line, self.column)
  self.ix += 1
  self.column += 1
  Spanning::single_width(token_position, Token::Punctuation(t))
}

///|
/// 残りのバイト列から次の 1 文字 (Unicode) を読む。EOF は None
fn Lexer::next_char(self : Lexer) -> Char? {
  if self.ix >= self.bytes.length() {
    return None
  }
  let n = num_bytes_in_char(self.bytes[self.ix])
  let end = if self.ix + n <= self.bytes.length() {
    self.ix + n
  } else {
    self.bytes.length()
  }
  let s = utf8_slice(self.bytes, self.ix, end)
  s.iter().head()
}

///|
fn Lexer::unexpected_char_error(self : Lexer) -> LexerError {
  match self.next_char() {
    Some(c) => UnexpectedCharacter(c)
    None => UnexpectedEndOfFile
  }
}

///|
pub fn Lexer::read_next_token(self : Lexer) -> LexResult? {
  // コメントと空白を読み飛ばしつつ次のトークンを返す
  while true {
    if self.ix >= self.bytes.length() {
      return None
    }
    let c = self.bytes[self.ix]
    if (c >= b'a' && c <= b'z') || (c >= b'A' && c <= b'Z') || c == b'_' {
      return Some(self.parse_name_token())
    } else if c == b' ' || c == b'\t' || c == b'\n' || c == b',' || c == b'\r' {
      self.scan_whitespace()
    } else if (c >= b'0' && c <= b'9') || c == b'-' {
      return Some(self.parse_number_token())
    } else if c == b'"' {
      return Some(self.parse_string_token())
    } else if c == b'#' {
      while self.ix < self.bytes.length() &&
            self.bytes[self.ix] != b'\r' &&
            self.bytes[self.ix] != b'\n' {
        self.ix += 1
      }
    } else if c == b'!' {
      return Some(Ok(self.consume_punctuation_token(Bang)))
    } else if c == b'$' {
      return Some(Ok(self.consume_punctuation_token(Dollar)))
    } else if c == b'&' {
      return Some(Ok(self.consume_punctuation_token(Amp)))
    } else if c == b'(' {
      return Some(Ok(self.consume_punctuation_token(ParenL)))
    } else if c == b')' {
      return Some(Ok(self.consume_punctuation_token(ParenR)))
    } else if c == b':' {
      return Some(Ok(self.consume_punctuation_token(Colon)))
    } else if c == b'=' {
      return Some(Ok(self.consume_punctuation_token(Equals)))
    } else if c == b'@' {
      return Some(Ok(self.consume_punctuation_token(At)))
    } else if c == b'[' {
      return Some(Ok(self.consume_punctuation_token(BracketL)))
    } else if c == b']' {
      return Some(Ok(self.consume_punctuation_token(BracketR)))
    } else if c == b'{' {
      return Some(Ok(self.consume_punctuation_token(BraceL)))
    } else if c == b'|' {
      return Some(Ok(self.consume_punctuation_token(Pipe)))
    } else if c == b'}' {
      return Some(Ok(self.consume_punctuation_token(BraceR)))
    } else if c == b'.' {
      return Some(self.parse_spread())
    } else {
      let parse_error = self.unexpected_char_error()
      return Some(Err(Positioned::new(self.get_position(), parse_error)))
    }
  }
  None
}

///|
fn Lexer::parse_spread(self : Lexer) -> LexResult {
  let mut count = 0
  while self.ix + count < self.bytes.length() &&
        self.bytes[self.ix + count] == b'.' {
    count += 1
  }
  if count >= 3 {
    self.ix += 3
    self.seek_column_by(3)
    Ok(
      Spanning::start_end(
        SourcePosition::new(self.line, self.column - 3),
        SourcePosition::new(self.line, self.column - 1),
        Token::Punctuation(Spread),
      ),
    )
  } else {
    self.ix += count
    self.seek_column_by(count)
    let parse_error = self.unexpected_char_error()
    Err(Positioned::new(self.get_position(), parse_error))
  }
}

///|
/// 不変条件: 先頭文字のチェック後に呼ぶこと
fn Lexer::parse_name_token(self : Lexer) -> LexResult {
  let start = self.ix
  let mut name_length = 0
  while self.ix + name_length < self.bytes.length() {
    let c = self.bytes[self.ix + name_length]
    if (c >= b'a' && c <= b'z') ||
      (c >= b'A' && c <= b'Z') ||
      (c >= b'0' && c <= b'9') ||
      c == b'_' {
      name_length += 1
    } else {
      break
    }
  }
  self.seek_column_by(name_length)
  self.ix += name_length
  let name = ascii_slice(self.bytes, start, self.ix)
  // 先頭文字チェック済みのため常に妥当
  let graphql_name = Name::new_unchecked(name)
  Ok(
    Spanning::start_end(
      SourcePosition::new(self.line, self.column - (self.ix - start)),
      SourcePosition::new(self.line, self.column - 1),
      Token::Name(graphql_name),
    ),
  )
}

///|
fn Lexer::parse_string_token(self : Lexer) -> LexResult {
  match parse_lexer_string(self.bytes, self.ix) {
    Ok((s, consumed, consumed_bytes)) => {
      self.ix += consumed_bytes
      let start_position = self.get_position()
      self.seek(consumed.line_breaks, consumed.chars_without_further_line_break)
      Ok(
        Spanning::start_end(
          start_position,
          // 文字列は常に " で終わるため column は必ず 1 より大きい
          SourcePosition::new(self.line, self.column - 1),
          Token::TString(s),
        ),
      )
    }
    Err((e, consumed)) => {
      self.seek(consumed.line_breaks, consumed.chars_without_further_line_break)
      Err(Positioned::new(self.get_position(), InvalidString(e)))
    }
  }
}

///|
fn Lexer::parse_number_token(self : Lexer) -> LexResult {
  match parse_lexer_number(self.bytes, self.ix) {
    Ok((number, consumed_bytes)) => {
      self.ix += consumed_bytes
      let consumed_chars = consumed_bytes
      let column_start = self.column
      let column_end = column_start + consumed_chars - 1
      self.seek_column_by(consumed_chars)
      Ok(
        Spanning::start_end(
          SourcePosition::new(self.line, column_start),
          SourcePosition::new(self.line, column_end),
          Token::Number(number),
        ),
      )
    }
    Err(e) => Err(Positioned::new(self.get_position(), InvalidNumber(e)))
  }
}

///|
fn Lexer::scan_whitespace(self : Lexer) -> Unit {
  while self.ix < self.bytes.length() {
    let c = self.bytes[self.ix]
    if c == b' ' || c == b'\t' || c == b',' {
      self.seek_column_by(1)
    } else if c == b'\n' {
      self.seek_lines(1)
    } else if c == b'\r' {
      // 次が '\n' の場合のみ行を進めない
      if !(self.ix + 1 < self.bytes.length() && self.bytes[self.ix + 1] == b'\n') {
        self.seek_lines(1)
      }
    } else {
      break
    }
    self.ix += 1
  }
}
