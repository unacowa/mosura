// lang-graphql/src/parser/value.rs の移植

///|
fn Parser::parse_number_value(
  self : Parser,
) -> Spanning[NumberToken] raise ParseErr {
  let expected = [ExpectedToken::Number]
  self.parse_token(expected, token => {
    match token.item {
      Token::Number(number) =>
        Spanning::start_end(token.start, token.end, number)
      _ => Parser::unexpected_token(expected, token.item, token.start)
    }
  })
}

///|
fn Parser::parse_string_value(self : Parser) -> Spanning[String] raise ParseErr {
  let expected = [ExpectedToken::TString]
  self.parse_token(expected, token => {
    match token.item {
      Token::TString(string) =>
        Spanning::start_end(token.start, token.end, string)
      _ => Parser::unexpected_token(expected, token.item, token.start)
    }
  })
}

///|
pub fn Parser::parse_optional_string(
  self : Parser,
) -> Spanning[String]? raise ParseErr {
  self.parse_optional(
    token => {
      match token {
        Token::TString(_) => true
        _ => false
      }
    },
    p => p.parse_string_value(),
  )
}

///|
fn Parser::parse_simple_value(
  self : Parser,
  expected_tokens : Array[ExpectedToken],
) -> Spanning[SimpleValue] raise ParseErr {
  let token = self.peek_fail(expected_tokens)
  match token.item {
    Token::Name(_) => {
      let token = self.parse_name()
      let name = token.item.as_str()
      let value : SimpleValue = if name == "false" {
        Boolean(false)
      } else if name == "true" {
        Boolean(true)
      } else if name == "null" {
        Null
      } else {
        SVEnum(token.item)
      }
      Spanning::start_end(token.start, token.end, value)
    }
    Token::Number(_) => {
      let token = self.parse_number_value()
      token.map(number => {
        match number {
          Float64(f) => SimpleValue::Float(f)
          Int64(i) => SimpleValue::Integer(i)
        }
      })
    }
    Token::TString(_) => {
      let token = self.parse_string_value()
      token.map(s => SimpleValue::SVString(s))
    }
    Token::Punctuation(_) =>
      Parser::unexpected_token(expected_tokens, token.item, token.start)
  }
}

///|
pub fn[T] Parser::parse_key_value(
  self : Parser,
  parse : (Parser) -> Spanning[T] raise ParseErr,
) -> Spanning[KeyValue[T]] raise ParseErr {
  let key = self.parse_name()
  ignore(self.parse_punctuation(Colon))
  let value = parse(self)
  Spanning::start_end(key.start, value.end, { key, value })
}

///|
pub fn Parser::parse_const_value(
  self : Parser,
) -> Spanning[ConstValue] raise ParseErr {
  self.with_recursion_limit(() => {
    let expected_tokens = [
      ExpectedToken::Number,
      ExpectedToken::TString,
      ExpectedToken::Keyword(True),
      ExpectedToken::Keyword(False),
      ExpectedToken::Keyword(Null),
      ExpectedToken::Punctuation(BracketL),
      ExpectedToken::Punctuation(BraceL),
    ]
    match self.peek_fail(expected_tokens).item {
      Token::Punctuation(BracketL) => {
        let list = self.parse_possibly_empty_delimited_list(
          BracketL,
          BracketR,
          p => p.parse_const_value(),
        )
        list.map(l => ConstValue::List(l))
      }
      Token::Punctuation(BraceL) => {
        let list = self.parse_possibly_empty_delimited_list(BraceL, BraceR, p => {
          p.parse_key_value(q => q.parse_const_value())
        })
        list.map(l => ConstValue::Object(l))
      }
      _ =>
        self
        .parse_simple_value(expected_tokens)
        .map(v => ConstValue::SimpleValue(v))
    }
  })
}

///|
pub fn Parser::parse_value(self : Parser) -> Spanning[Value] raise ParseErr {
  self.with_recursion_limit(() => {
    let expected_tokens = [
      ExpectedToken::Number,
      ExpectedToken::TString,
      ExpectedToken::Keyword(True),
      ExpectedToken::Keyword(False),
      ExpectedToken::Keyword(Null),
      ExpectedToken::Punctuation(Dollar),
      ExpectedToken::Punctuation(BracketL),
      ExpectedToken::Punctuation(BraceL),
    ]
    match self.peek_fail(expected_tokens).item {
      // $variable
      Token::Punctuation(Dollar) => {
        let punctuation = self.parse_punctuation(Dollar)
        let variable_name = self.parse_name()
        Spanning::start_end(
          punctuation.start,
          variable_name.end,
          Value::Variable(variable_name.item),
        )
      }
      Token::Punctuation(BracketL) => {
        let list = self.parse_possibly_empty_delimited_list(
          BracketL,
          BracketR,
          p => p.parse_value(),
        )
        list.map(l => Value::List(l))
      }
      Token::Punctuation(BraceL) => {
        let list = self.parse_possibly_empty_delimited_list(BraceL, BraceR, p => {
          p.parse_key_value(q => q.parse_value())
        })
        list.map(l => Value::Object(l))
      }
      _ =>
        self.parse_simple_value(expected_tokens).map(v => Value::SimpleValue(v))
    }
  })
}
