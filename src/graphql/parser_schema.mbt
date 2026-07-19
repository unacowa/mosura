// lang-graphql/src/parser/schema.rs の移植 (SDL パーサ)

///|
fn[T, U] get_start_position(
  first_token : Spanning[T]?,
  second_token : Spanning[U],
) -> SourcePosition {
  match first_token {
    Some(t) => t.start
    None => second_token.start
  }
}

///|
fn[T, U] get_end_position(
  preceding_token : Spanning[T],
  repeated_tokens : Array[Spanning[U]],
) -> SourcePosition {
  match repeated_tokens.last() {
    Some(last_token) => last_token.end
    None => preceding_token.end
  }
}

///|
/// `@ Name ConstArguments`
fn Parser::parse_const_directive(
  self : Parser,
) -> Spanning[ConstDirective] raise ParseErr {
  let start_position = self.parse_punctuation(At).start
  let name = self.parse_name()
  let arguments = self.parse_const_arguments()
  let end_position = match arguments {
    Some(l) => l.end
    None => name.end
  }
  Spanning::start_end(start_position, end_position, ConstDirective::{
    name,
    arguments,
  })
}

///|
fn Parser::parse_const_directives(
  self : Parser,
) -> Array[Spanning[ConstDirective]] raise ParseErr {
  self.parse_list(p => p.is_next_token(Token::Punctuation(At)), p => {
    p.parse_const_directive()
  })
}

///|
fn Parser::parse_schema_definition(
  self : Parser,
  description : Spanning[String]?,
) -> Spanning[SchemaDefinition] raise ParseErr {
  let start_position = get_start_position(
    description,
    self.parse_keyword(Schema),
  )
  let directives = self.parse_const_directives()
  let operation_types = self.parse_nonempty_delimited_list(BraceL, BraceR, s => {
    let operation_type = s.parse_operation_type()
    ignore(s.parse_punctuation(Colon))
    let type_name = s.parse_name()
    Spanning::start_end(
      operation_type.start,
      type_name.end,
      (operation_type, type_name),
    )
  })
  Spanning::start_end(start_position, operation_types.end, SchemaDefinition::{
    description,
    is_extension: false,
    directives,
    operation_types: operation_types.item,
  })
}

///|
fn Parser::parse_scalar_definition(
  self : Parser,
  description : Spanning[String]?,
) -> Spanning[ScalarTypeDefinition] raise ParseErr {
  let start_position = get_start_position(
    description,
    self.parse_keyword(Scalar),
  )
  let name = self.parse_name()
  let directives = self.parse_const_directives()
  Spanning::start_end(start_position, get_end_position(name, directives), ScalarTypeDefinition::{
    is_extension: false,
    description,
    name,
    directives,
  })
}

///|
fn Parser::parse_field_arguments(
  self : Parser,
) -> Spanning[Array[Spanning[InputValueDefinition]]]? raise ParseErr {
  self.parse_optional_nonempty_delimited_list(ParenL, ParenR, p => {
    p.parse_input_value_definition()
  })
}

///|
fn Parser::parse_const_arguments(
  self : Parser,
) -> Spanning[Array[ConstArgument]]? raise ParseErr {
  self.parse_optional_nonempty_delimited_list(ParenL, ParenR, p => {
    p.parse_key_value(q => q.parse_const_value())
  })
}

///|
fn Parser::parse_input_value_definition(
  self : Parser,
) -> Spanning[InputValueDefinition] raise ParseErr {
  let description = self.parse_optional_string()
  let name = self.parse_name()
  ignore(self.parse_punctuation(Colon))
  let field_type = self.parse_type()
  let default_value = if self.is_next_token(Token::Punctuation(Equals)) {
    ignore(self.parse_punctuation(Equals))
    Some(self.parse_const_value())
  } else {
    None
  }
  let end_position = match default_value {
    Some(l) => l.end
    None => field_type.end
  }
  let directives = self.parse_const_directives()
  Spanning::start_end(get_start_position(description, name), end_position, InputValueDefinition::{
    description,
    name,
    ty: field_type,
    default_value,
    directives,
  })
}

///|
fn Parser::parse_field_definition(
  self : Parser,
) -> Spanning[FieldDefinition] raise ParseErr {
  let description = self.parse_optional_string()
  let name = self.parse_name()
  let arguments = self.parse_field_arguments()
  ignore(self.parse_punctuation(Colon))
  let field_type = self.parse_type()
  let directives = self.parse_const_directives()
  Spanning::start_end(
    get_start_position(description, name),
    get_end_position(field_type, directives),
    FieldDefinition::{
      description,
      name,
      ty: field_type,
      arguments: match arguments {
        Some(v) => v.item
        None => []
      },
      directives,
    },
  )
}

///|
fn Parser::parse_fields_definition(
  self : Parser,
) -> Spanning[Array[Spanning[FieldDefinition]]] raise ParseErr {
  self.parse_nonempty_delimited_list(BraceL, BraceR, p => {
    p.parse_field_definition()
  })
}

///|
fn Parser::parse_amp_separated_names(
  self : Parser,
) -> Array[Spanning[Name]] raise ParseErr {
  self.parse_list(s => s.is_next_token(Token::Punctuation(Amp)), s => {
    ignore(s.parse_punctuation(Amp))
    s.parse_name()
  })
}

///|
fn Parser::parse_implements(
  self : Parser,
) -> Array[Spanning[Name]] raise ParseErr {
  let has_implements = self.parse_optional(
    token => {
      match token {
        Token::Name(name) => name.as_str() == Keyword::Implements.as_str()
        _ => false
      }
    },
    parser => parser.parse_keyword(Implements),
  )
  if has_implements is Some(_) {
    let expected_tokens = [ExpectedToken::Punctuation(Amp), ExpectedToken::Name]
    match self.peek() {
      None => self.eof(expected_tokens)
      Some(Err(e)) => Parser::lexer_error(e, expected_tokens)
      Some(Ok(token)) =>
        match token.item {
          Token::Punctuation(Amp) => self.parse_amp_separated_names()
          Token::Name(_) => {
            let members = [self.parse_name()]
            members.append(self.parse_amp_separated_names())
            members
          }
          _ =>
            Parser::unexpected_token(expected_tokens, token.item, token.start)
        }
    }
  } else {
    []
  }
}

///|
fn Parser::parse_object_definition(
  self : Parser,
  description : Spanning[String]?,
) -> Spanning[ObjectTypeDefinition] raise ParseErr {
  let start_position = get_start_position(description, self.parse_keyword(Type))
  let name = self.parse_name()
  let implements = self.parse_implements()
  let directives = self.parse_const_directives()
  let fields = self.parse_fields_definition()
  Spanning::start_end(start_position, fields.end, ObjectTypeDefinition::{
    description,
    name,
    directives,
    is_extension: false,
    implements,
    fields: fields.item,
  })
}

///|
fn Parser::parse_interface_definition(
  self : Parser,
  description : Spanning[String]?,
) -> Spanning[InterfaceTypeDefinition] raise ParseErr {
  let start_position = get_start_position(
    description,
    self.parse_keyword(Interface),
  )
  let name = self.parse_name()
  let implements = self.parse_implements()
  let directives = self.parse_const_directives()
  let fields = self.parse_fields_definition()
  Spanning::start_end(start_position, fields.end, InterfaceTypeDefinition::{
    description,
    name,
    directives,
    is_extension: false,
    implements,
    fields: fields.item,
  })
}

///|
fn Parser::parse_pipe_separated_names(
  self : Parser,
) -> Array[Spanning[Name]] raise ParseErr {
  self.parse_list(s => s.is_next_token(Token::Punctuation(Pipe)), s => {
    ignore(s.parse_punctuation(Pipe))
    s.parse_name()
  })
}

///|
fn Parser::parse_union_members(
  self : Parser,
) -> Array[Spanning[Name]] raise ParseErr {
  let has_equals = self.parse_optional(
    token => {
      match token {
        Token::Punctuation(Equals) => true
        _ => false
      }
    },
    parser => parser.parse_punctuation(Equals),
  )
  if has_equals is Some(_) {
    let expected_tokens = [
      ExpectedToken::Punctuation(Pipe),
      ExpectedToken::Name,
    ]
    match self.peek() {
      None => self.eof(expected_tokens)
      Some(Err(e)) => Parser::lexer_error(e, expected_tokens)
      Some(Ok(token)) =>
        match token.item {
          Token::Punctuation(Pipe) => self.parse_pipe_separated_names()
          Token::Name(_) => {
            let members = [self.parse_name()]
            members.append(self.parse_pipe_separated_names())
            members
          }
          _ =>
            Parser::unexpected_token(expected_tokens, token.item, token.start)
        }
    }
  } else {
    []
  }
}

///|
fn Parser::parse_union_definition(
  self : Parser,
  description : Spanning[String]?,
) -> Spanning[UnionTypeDefinition] raise ParseErr {
  let start_position = get_start_position(
    description,
    self.parse_keyword(Union),
  )
  let name = self.parse_name()
  let directives = self.parse_const_directives()
  let members = self.parse_union_members()
  let end_position = match members.last() {
    Some(last_member) => last_member.end
    None => get_end_position(name, directives)
  }
  Spanning::start_end(start_position, end_position, UnionTypeDefinition::{
    description,
    name,
    directives,
    is_extension: false,
    members,
  })
}

///|
fn Parser::parse_enum_definition(
  self : Parser,
  description : Spanning[String]?,
) -> Spanning[EnumTypeDefinition] raise ParseErr {
  let start_position = get_start_position(description, self.parse_keyword(Enum))
  let name = self.parse_name()
  let directives = self.parse_const_directives()
  let values = self.parse_nonempty_delimited_list(BraceL, BraceR, s => {
    let description = s.parse_optional_string()
    let value = s.parse_name()
    let directives = s.parse_const_directives()
    Spanning::start_end(
      get_start_position(description, value),
      get_end_position(value, directives),
      EnumValueDefinition::{ description, value, directives },
    )
  })
  Spanning::start_end(start_position, values.end, EnumTypeDefinition::{
    description,
    name,
    directives,
    is_extension: false,
    values: values.item,
  })
}

///|
fn Parser::parse_input_definition(
  self : Parser,
  description : Spanning[String]?,
) -> Spanning[InputObjectTypeDefinition] raise ParseErr {
  let start_position = get_start_position(
    description,
    self.parse_keyword(Input),
  )
  let name = self.parse_name()
  let directives = self.parse_const_directives()
  let fields = self.parse_nonempty_delimited_list(BraceL, BraceR, p => {
    p.parse_input_value_definition()
  })
  Spanning::start_end(start_position, fields.end, InputObjectTypeDefinition::{
    description,
    name,
    directives,
    is_extension: false,
    fields: fields.item,
  })
}

///|
fn Parser::parse_type_system_definition(
  self : Parser,
) -> Spanning[TypeSystemDefinition] raise ParseErr {
  let expected_tokens = [
    ExpectedToken::Keyword(Schema),
    ExpectedToken::Keyword(Scalar),
    ExpectedToken::Keyword(Type),
    ExpectedToken::Keyword(Interface),
    ExpectedToken::Keyword(Union),
    ExpectedToken::Keyword(Enum),
    ExpectedToken::Keyword(Input),
  ]
  let description = self.parse_optional_string()
  match self.peek() {
    None => self.eof(expected_tokens)
    Some(Err(e)) => Parser::lexer_error(e, expected_tokens)
    Some(Ok(token)) =>
      match token.item {
        Token::Name(name) =>
          match name.as_str() {
            "schema" =>
              self
              .parse_schema_definition(description)
              .map(s => TypeSystemDefinition::Schema(s))
            "scalar" =>
              self
              .parse_scalar_definition(description)
              .map(d => TypeSystemDefinition::Type(TypeDefinition::Scalar(d)))
            "type" =>
              self
              .parse_object_definition(description)
              .map(d => TypeSystemDefinition::Type(TypeDefinition::Object(d)))
            "interface" =>
              self
              .parse_interface_definition(description)
              .map(d => TypeSystemDefinition::Type(TypeDefinition::Interface(d)))
            "union" =>
              self
              .parse_union_definition(description)
              .map(d => TypeSystemDefinition::Type(TypeDefinition::Union(d)))
            "enum" =>
              self
              .parse_enum_definition(description)
              .map(d => TypeSystemDefinition::Type(TypeDefinition::Enum(d)))
            "input" =>
              self
              .parse_input_definition(description)
              .map(d => {
                TypeSystemDefinition::Type(TypeDefinition::InputObject(d))
              })
            _ =>
              Parser::unexpected_token(expected_tokens, token.item, token.start)
          }
        _ => Parser::unexpected_token(expected_tokens, token.item, token.start)
      }
  }
}

///|
/// SDL のトップレベルパーサ
pub fn Parser::parse_schema_document(
  self : Parser,
) -> SchemaDocument raise ParseErr {
  let definitions = []
  while self.peek() is Some(_) {
    definitions.push(self.parse_type_system_definition())
  }
  { definitions, }
}
