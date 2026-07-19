// lang-graphql/src/parser/selection_set.rs + fragment.rs の移植

///|
pub fn Parser::parse_type_condition(
  self : Parser,
) -> Spanning[TypeCondition] raise ParseErr {
  let on = self.parse_keyword(On)
  let type_name = self.parse_name()
  Spanning::start_end(on.start, type_name.end, {
    on: type_name.map(n => TypeName(n)),
  })
}

///|
fn Parser::parse_selection(self : Parser) -> Spanning[Selection] raise ParseErr {
  let expected_tokens = [
    ExpectedToken::Name,
    ExpectedToken::Punctuation(Spread),
  ]
  let token = self.peek_fail(expected_tokens)
  match token.item {
    Token::Name(_) => self.parse_field().map(f => Selection::Field(f))
    Token::Punctuation(Spread) => self.parse_spread_selection()
    _ => Parser::unexpected_token(expected_tokens, token.item, token.start)
  }
}

///|
pub fn Parser::parse_selection_set(
  self : Parser,
) -> Spanning[SelectionSet] raise ParseErr {
  self.with_recursion_limit(() => {
    self
    .parse_nonempty_delimited_list(BraceL, BraceR, p => p.parse_selection())
    .map(l => SelectionSet::{ items: l })
  })
}

///|
fn Parser::parse_field(self : Parser) -> Spanning[Field] raise ParseErr {
  let name1 = self.parse_name()
  let name2 = if self.is_next_token(Token::Punctuation(Colon)) {
    ignore(self.parse_punctuation(Colon))
    Some(self.parse_name())
  } else {
    None
  }
  let (field_alias, name) = match name2 {
    Some(name) => (Some(name1.map(n => Alias::new(n))), name)
    None => (None, name1)
  }
  let arguments = self.parse_arguments()
  let directives = self.parse_directives()
  let selection_set = if self.is_next_token(Token::Punctuation(BraceL)) {
    Some(self.parse_selection_set())
  } else {
    None
  }
  Spanning::start_end(name.start, name.end, Field::{
    field_alias,
    name,
    arguments,
    directives,
    selection_set,
  })
}

///|
fn Parser::parse_spread_selection(
  self : Parser,
) -> Spanning[Selection] raise ParseErr {
  let spread = self.parse_punctuation(Spread)
  let is_inline_spread = self.is_next_token_keyword(On) ||
    self.is_next_token(Token::Punctuation(At)) ||
    self.is_next_token(Token::Punctuation(BraceL))
  if is_inline_spread {
    let type_condition = if self.is_next_token_keyword(On) {
      Some(self.parse_type_condition())
    } else {
      None
    }
    let directives = self.parse_directives()
    let selection_set = self.parse_selection_set()
    Spanning::start_end(
      spread.start,
      selection_set.end,
      Selection::InlineFragment({ type_condition, directives, selection_set }),
    )
  } else {
    let fragment_name = self.parse_name()
    let directives = self.parse_directives()
    Spanning::start_end(
      spread.start,
      fragment_name.end,
      Selection::FragmentSpread({ fragment_name, directives }),
    )
  }
}

///|
pub fn Parser::parse_arguments(
  self : Parser,
) -> Spanning[Array[Argument]]? raise ParseErr {
  self.parse_optional_nonempty_delimited_list(ParenL, ParenR, p => {
    p.parse_key_value(q => q.parse_value())
  })
}

///|
/// `@ Name Arguments`
fn Parser::parse_directive(self : Parser) -> Spanning[Directive] raise ParseErr {
  let start_position = self.parse_punctuation(At).start
  let name = self.parse_name()
  let arguments = self.parse_arguments()
  let end_position = match arguments {
    Some(l) => l.end
    None => name.end
  }
  Spanning::start_end(start_position, end_position, Directive::{
    name,
    arguments,
  })
}

///|
pub fn Parser::parse_directives(
  self : Parser,
) -> Array[Spanning[Directive]] raise ParseErr {
  self.parse_list(p => p.is_next_token(Token::Punctuation(At)), p => {
    p.parse_directive()
  })
}

///|
pub fn Parser::parse_fragment(
  self : Parser,
) -> Spanning[FragmentDefinition] raise ParseErr {
  let start_position = self.parse_keyword(Fragment).start
  let name = self.parse_name()
  if name.item.as_str() == "on" {
    Parser::other_error(
      "A fragment may not be named \"on\". Maybe you forgot the name?",
      name.start,
    )
  } else {
    let type_condition = self.parse_type_condition()
    let directives = self.parse_directives()
    let selection_set = self.parse_selection_set()
    Spanning::start_end(start_position, selection_set.end, FragmentDefinition::{
      name,
      type_condition,
      directives,
      selection_set,
    })
  }
}
