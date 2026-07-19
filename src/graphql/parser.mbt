// lang-graphql/src/parser.rs の移植 (コア部分)

///|
pub(all) enum Keyword {
  True
  False
  Null
  Fragment
  On
  Query
  Mutation
  Subscription
  Type
  Input
  Enum
  Scalar
  Implements
  Interface
  Union
  Schema
} derive(Eq)

///|
pub fn Keyword::as_str(self : Keyword) -> String {
  match self {
    True => "true"
    False => "false"
    Null => "null"
    Fragment => "fragment"
    On => "on"
    Query => "query"
    Mutation => "mutation"
    Subscription => "subscription"
    Type => "type"
    Input => "input"
    Enum => "enum"
    Scalar => "scalar"
    Interface => "interface"
    Union => "union"
    Schema => "schema"
    Implements => "implements"
  }
}

///|
/// トークンの「種類」
pub(all) enum ExpectedToken {
  Keyword(Keyword)
  Punctuation(Punctuation)
  Name
  Number
  TString
} derive(Eq)

///|
pub(all) enum TokenFound {
  EndOfFile
  LexerError(LexerError)
  Token(Token)
} derive(Eq)

///|
pub(all) enum ParseError {
  TokenError(expected_tokens~ : Array[ExpectedToken], found~ : TokenFound)
  OtherError(String)
} derive(Eq)

///|
/// パーサの失敗 (位置つき)
pub suberror ParseErr {
  ParseErr(Positioned[ParseError])
}

///|
pub(all) struct Parser {
  lexer : Lexer
  mut next_token : LexResult?
  mut recursion_limit : Int
}

///|
pub fn Parser::new(source : Bytes) -> Parser {
  let lexer = Lexer::new(source)
  let parser : Parser = { lexer, next_token: None, recursion_limit: 100 }
  ignore(parser.advance())
  parser
}

///|
pub fn Parser::peek(self : Parser) -> LexResult? {
  self.next_token
}

///|
pub fn Parser::is_next_token(self : Parser, expected : Token) -> Bool {
  match self.peek() {
    Some(Ok(token)) => token.item == expected
    _ => false
  }
}

///|
pub fn Parser::is_next_token_keyword(self : Parser, expected : Keyword) -> Bool {
  match self.peek() {
    Some(Ok({ item: Token::Name(name), .. })) =>
      name.as_str() == expected.as_str()
    _ => false
  }
}

///|
fn Parser::advance(self : Parser) -> LexResult? {
  let current_token = self.next_token
  self.next_token = self.lexer.read_next_token()
  current_token
}

///|
fn[T] Parser::eof(
  self : Parser,
  expected_tokens : Array[ExpectedToken],
) -> T raise ParseErr {
  raise ParseErr(
    Positioned::new(
      self.lexer.get_position(),
      TokenError(expected_tokens~, found=EndOfFile),
    ),
  )
}

///|
fn[T] Parser::lexer_error(
  error : Positioned[LexerError],
  expected_tokens : Array[ExpectedToken],
) -> T raise ParseErr {
  raise ParseErr(
    Positioned::new(
      error.position,
      TokenError(expected_tokens~, found=LexerError(error.item)),
    ),
  )
}

///|
fn[T] Parser::other_error(
  error_msg : String,
  start : SourcePosition,
) -> T raise ParseErr {
  raise ParseErr(Positioned::new(start, OtherError(error_msg)))
}

///|
/// 現在位置でエラーを作る (再帰制限用)
fn[T] Parser::error_str(self : Parser, error_msg : String) -> T raise ParseErr {
  raise ParseErr(
    Positioned::new(self.lexer.get_position(), OtherError(error_msg)),
  )
}

///|
fn[T] Parser::unexpected_token(
  expected_tokens : Array[ExpectedToken],
  found : Token,
  location : SourcePosition,
) -> T raise ParseErr {
  raise ParseErr(
    Positioned::new(location, TokenError(expected_tokens~, found=Token(found))),
  )
}

///|
/// 再帰制限 (#[limit_recursion] 相当)
fn[T] Parser::with_recursion_limit(
  self : Parser,
  f : () -> T raise ParseErr,
) -> T raise ParseErr {
  self.recursion_limit -= 1
  if self.recursion_limit <= 0 {
    let _ : Unit = self.error_str("Recursion limit exceeded")
  }
  try {
    let v = f()
    self.recursion_limit += 1
    v
  } catch {
    e => {
      self.recursion_limit += 1
      raise e
    }
  }
}

///|
pub fn Parser::peek_fail(
  self : Parser,
  expected_tokens : Array[ExpectedToken],
) -> Spanning[Token] raise ParseErr {
  match self.peek() {
    None => self.eof(expected_tokens)
    Some(Err(error)) => Parser::lexer_error(error, expected_tokens)
    Some(Ok(token)) => token
  }
}

///|
pub fn[T] Parser::parse_token(
  self : Parser,
  expected_tokens : Array[ExpectedToken],
  parse : (Spanning[Token]) -> T raise ParseErr,
) -> T raise ParseErr {
  match self.advance() {
    None => self.eof(expected_tokens)
    Some(Err(error)) => Parser::lexer_error(error, expected_tokens)
    Some(Ok(token)) => parse(token)
  }
}

///|
fn Parser::parse_keyword(
  self : Parser,
  keyword : Keyword,
) -> Spanning[Name] raise ParseErr {
  let expected = [ExpectedToken::Keyword(keyword)]
  self.parse_token(expected, token => {
    match token.item {
      Token::Name(name) if name.as_str() == keyword.as_str() =>
        Spanning::start_end(token.start, token.end, name)
      _ => Parser::unexpected_token(expected, token.item, token.start)
    }
  })
}

///|
fn Parser::parse_name(self : Parser) -> Spanning[Name] raise ParseErr {
  let expected = [ExpectedToken::Name]
  self.parse_token(expected, token => {
    match token.item {
      Token::Name(name) => Spanning::start_end(token.start, token.end, name)
      _ => Parser::unexpected_token(expected, token.item, token.start)
    }
  })
}

///|
fn Parser::parse_punctuation(
  self : Parser,
  punctuation : Punctuation,
) -> Spanning[Punctuation] raise ParseErr {
  let expected = [ExpectedToken::Punctuation(punctuation)]
  self.parse_token(expected, token => {
    match token.item {
      Token::Punctuation(found) if punctuation == found =>
        Spanning::start_end(token.start, token.end, found)
      _ => Parser::unexpected_token(expected, token.item, token.start)
    }
  })
}

///|
fn[T] Parser::parse_list(
  self : Parser,
  peek : (Parser) -> Bool,
  parse : (Parser) -> T raise ParseErr,
) -> Array[T] raise ParseErr {
  let items = []
  while peek(self) {
    items.push(parse(self))
  }
  items
}

///|
/// `<start> <item>+ <end>`
fn[T] Parser::parse_nonempty_delimited_list(
  self : Parser,
  start_token : Punctuation,
  end_token : Punctuation,
  parse : (Parser) -> T raise ParseErr,
) -> Spanning[Array[T]] raise ParseErr {
  self.parse_delimited_list_helper(start_token, end_token, parse, true)
}

///|
/// `<start> <item>* <end>`
fn[T] Parser::parse_possibly_empty_delimited_list(
  self : Parser,
  start_token : Punctuation,
  end_token : Punctuation,
  parse : (Parser) -> T raise ParseErr,
) -> Spanning[Array[T]] raise ParseErr {
  self.parse_delimited_list_helper(start_token, end_token, parse, false)
}

///|
fn[T] Parser::parse_delimited_list_helper(
  self : Parser,
  start_token : Punctuation,
  end_token : Punctuation,
  parse : (Parser) -> T raise ParseErr,
  must_be_nonempty : Bool,
) -> Spanning[Array[T]] raise ParseErr {
  let start = self.parse_punctuation(start_token)
  let items = []
  while !self.is_next_token(Token::Punctuation(end_token)) {
    items.push(parse(self))
  }
  let end = self.parse_punctuation(end_token)
  if must_be_nonempty && items.is_empty() {
    Parser::other_error("At least one item must be specified", end.start)
  } else {
    Spanning::start_end(start.start, end.end, items)
  }
}

///|
/// `(<start> <item>+ <end>)?`
fn[T] Parser::parse_optional_nonempty_delimited_list(
  self : Parser,
  start_token : Punctuation,
  end_token : Punctuation,
  parse : (Parser) -> T raise ParseErr,
) -> Spanning[Array[T]]? raise ParseErr {
  if self.is_next_token(Token::Punctuation(start_token)) {
    Some(self.parse_delimited_list_helper(start_token, end_token, parse, true))
  } else {
    None
  }
}

///|
fn[T] Parser::parse_optional(
  self : Parser,
  peek : (Token) -> Bool,
  parse : (Parser) -> T raise ParseErr,
) -> T? raise ParseErr {
  match self.peek() {
    Some(Ok(token)) => if peek(token.item) { Some(parse(self)) } else { None }
    _ => None
  }
}

///|
pub fn ExpectedToken::display(self : ExpectedToken) -> String {
  match self {
    Keyword(keyword) => "Keyword(\{keyword.as_str()}"
    Punctuation(p) => "Punctuation(\{p.as_str()}"
    Name => "Name"
    Number => "Number"
    TString => "String"
  }
}

///|
pub fn LexerError::display(self : LexerError) -> String {
  match self {
    UnexpectedCharacter(c) => "unexpected character in the document: '\{c}'"
    UnexpectedEndOfFile => "end of file reached when expecting further input"
    InvalidString(_) => "invalid string literal found"
    InvalidNumber(_) => "invalid number literal found"
    InvalidGraphQlName(s) => "invalid graphql name: \{s}"
  }
}

///|
pub fn TokenFound::display(self : TokenFound) -> String {
  match self {
    EndOfFile => "end of file"
    LexerError(e) => "lexer error: \{e.display()}"
    Token(token) => "token: \{token.display()}"
  }
}

///|
/// Rust の Display 実装と同じ書式 (エラーレスポンス用)
pub fn ParseError::display(self : ParseError) -> String {
  match self {
    TokenError(expected_tokens~, found~) => {
      let mut acc = ""
      for expected_token in expected_tokens {
        acc = acc + expected_token.display() + ", "
      }
      "expected one of \{acc}, but encountered: \{found.display()}"
    }
    OtherError(msg) => msg
  }
}
