// lang-graphql/src/parser/executable.rs の移植

///|
fn Parser::parse_base_type(self : Parser) -> Spanning[BaseType] raise ParseErr {
  let expected_tokens = [
    ExpectedToken::Name,
    ExpectedToken::Punctuation(BracketL),
  ]
  match self.peek() {
    None => self.eof(expected_tokens)
    Some(Err(e)) => Parser::lexer_error(e, expected_tokens)
    Some(Ok(token)) =>
      match token.item {
        Token::Name(_) =>
          self.parse_name().map(n => BaseTypeContainer::Named(TypeName(n)))
        Token::Punctuation(BracketL) => {
          let start_position = self.parse_punctuation(BracketL).start
          let wrapped_type = self.parse_type()
          let end_position = self.parse_punctuation(BracketR).start
          Spanning::start_end(
            start_position,
            end_position,
            BaseTypeContainer::List(wrapped_type.item),
          )
        }
        _ => Parser::unexpected_token(expected_tokens, token.item, token.start)
      }
  }
}

///|
pub fn Parser::parse_type(self : Parser) -> Spanning[GType] raise ParseErr {
  self.with_recursion_limit(() => {
    let base = self.parse_base_type()
    let bang = if self.is_next_token(Token::Punctuation(Bang)) {
      Some(self.parse_punctuation(Bang))
    } else {
      None
    }
    let nullable = bang is None
    let end = match bang {
      Some(p) => p.end
      None => base.end
    }
    Spanning::start_end(base.start, end, { base: base.item, nullable })
  })
}

///|
fn Parser::parse_variable_definition(
  self : Parser,
) -> Spanning[VariableDefinition] raise ParseErr {
  let start_position = self.parse_punctuation(Dollar).start
  let name = self.parse_name()
  ignore(self.parse_punctuation(Colon))
  let var_type = self.parse_type()
  let default_value = if self.is_next_token(Token::Punctuation(Equals)) {
    ignore(self.parse_punctuation(Equals))
    Some(self.parse_const_value())
  } else {
    None
  }
  let end_position = match default_value {
    Some(l) => l.end
    None => var_type.end
  }
  Spanning::start_end(start_position, end_position, VariableDefinition::{
    name,
    var_type,
    default_value,
  })
}

///|
pub fn Parser::parse_variable_definitions(
  self : Parser,
) -> Spanning[Array[Spanning[VariableDefinition]]]? raise ParseErr {
  self.parse_optional_nonempty_delimited_list(ParenL, ParenR, p => {
    p.parse_variable_definition()
  })
}

///|
pub fn Parser::parse_operation_type(
  self : Parser,
) -> Spanning[OperationType] raise ParseErr {
  let expected_tokens = [
    ExpectedToken::Keyword(Query),
    ExpectedToken::Keyword(Mutation),
    ExpectedToken::Keyword(Subscription),
  ]
  match self.peek() {
    None => self.eof(expected_tokens)
    Some(Err(e)) => Parser::lexer_error(e, expected_tokens)
    Some(Ok(token)) =>
      match token.item {
        Token::Name(_) => {
          let token = self.parse_name()
          if token.item.as_str() == Keyword::Query.as_str() {
            Spanning::start_end(token.start, token.end, OperationType::Query)
          } else if token.item.as_str() == Keyword::Mutation.as_str() {
            Spanning::start_end(token.start, token.end, OperationType::Mutation)
          } else if token.item.as_str() == Keyword::Subscription.as_str() {
            Spanning::start_end(
              token.start,
              token.end,
              OperationType::Subscription,
            )
          } else {
            Parser::unexpected_token(
              expected_tokens,
              Token::Name(token.item),
              token.start,
            )
          }
        }
        _ => Parser::unexpected_token(expected_tokens, token.item, token.start)
      }
  }
}

///|
pub fn Parser::parse_operation(
  self : Parser,
) -> Spanning[OperationDefinition] raise ParseErr {
  let expected_tokens = [
    ExpectedToken::Keyword(Query),
    ExpectedToken::Keyword(Mutation),
    ExpectedToken::Keyword(Subscription),
    ExpectedToken::Punctuation(BraceL),
  ]
  let operation_type : Spanning[OperationType]? = match self.peek() {
    None => self.eof(expected_tokens)
    Some(Err(e)) => Parser::lexer_error(e, expected_tokens)
    Some(Ok(token)) =>
      match token.item {
        Token::Name(_) => Some(self.parse_operation_type())
        Token::Punctuation(BraceL) => None
        _ => Parser::unexpected_token(expected_tokens, token.item, token.start)
      }
  }
  match operation_type {
    Some(operation_type) => {
      let name = match self.peek() {
        Some(Ok({ item: Token::Name(_), .. })) => Some(self.parse_name())
        _ => None
      }
      let variable_definitions = self.parse_variable_definitions()
      let directives = self.parse_directives()
      let selection_set = self.parse_selection_set()
      Spanning::start_end(operation_type.start, selection_set.end, OperationDefinition::{
        ty: operation_type.item,
        name,
        variable_definitions,
        directives,
        selection_set,
      })
    }
    None => {
      let selection_set = self.parse_selection_set()
      Spanning::start_end(selection_set.start, selection_set.end, OperationDefinition::{
        ty: OperationType::Query,
        name: None,
        variable_definitions: None,
        directives: [],
        selection_set,
      })
    }
  }
}

///|
/// https://spec.graphql.org/October2021/#sec-Executable-Definitions
pub fn Parser::parse_executable_definition(
  self : Parser,
) -> Spanning[ExecutableDefinition] raise ParseErr {
  let expected_tokens = [
    ExpectedToken::Keyword(Query),
    ExpectedToken::Keyword(Mutation),
    ExpectedToken::Keyword(Subscription),
    ExpectedToken::Keyword(Fragment),
    ExpectedToken::Punctuation(BraceL),
  ]
  match self.peek() {
    None => self.eof(expected_tokens)
    Some(Err(e)) => Parser::lexer_error(e, expected_tokens)
    Some(Ok(token)) =>
      match token.item {
        Token::Name(name) =>
          if name.as_str() == Keyword::Fragment.as_str() {
            self.parse_fragment().map(f => ExecutableDefinition::Fragment(f))
          } else {
            self.parse_operation().map(o => ExecutableDefinition::Operation(o))
          }
        Token::Punctuation(BraceL) =>
          self.parse_operation().map(o => ExecutableDefinition::Operation(o))
        _ => Parser::unexpected_token(expected_tokens, token.item, token.start)
      }
  }
}

///|
/// GraphQL リクエストのトップレベルパーサ
pub fn Parser::parse_executable_document(
  self : Parser,
) -> ExecutableDocument raise ParseErr {
  let items = []
  while self.peek() is Some(_) {
    items.push(self.parse_executable_definition())
  }
  { items, }
}
