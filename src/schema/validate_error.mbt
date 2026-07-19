// lang-graphql/src/validation/error.rs の移植。
// display() は thiserror の #[error(...)] 書式と一致させる (E2E のエラーレスポンス照合に使う)

///|
pub suberror ValidationError {
  CycleDetected(Array[String])
  UnknownFragment(String)
  FragmentOnNonCompositeType(fragment_name~ : String?, type_name~ : String)
  FragmentCannotBeSpread(selection_type~ : String, fragment_type~ : String)
  NoFieldOnType(type_name~ : String, field_name~ : String)
  UnknownType(String)
  InternalTypeNotFound(type_name~ : String)
  InternalNoFieldOnSubtype(
    type_name~ : String,
    sub_type_name~ : String,
    field_name~ : String
  )
  FieldsConflictDifferentFields(
    nalias~ : String,
    field1~ : String,
    field2~ : String
  )
  FieldsConflictDifferingTypes(
    nalias~ : String,
    type1~ : String,
    type2~ : String
  )
  FieldsConflictDifferingArguments(nalias~ : String)
  IncorrectFormat(expected_type~ : String, actual_type~ : String)
  UnexpectedNull(expected_type~ : String)
  InputFieldNotFound(type_name~ : String, field_name~ : String)
  DuplicateInputFields(type_name~ : String, field~ : String)
  EnumValueNotFound(type_name~ : String, enum_value~ : String)
  NotInputType(variable_name~ : String, type_name~ : String)
  InternalNotInputType(type_name~ : String, actual_type~ : String)
  VariableNotDefined(variable_name~ : String)
  VariableSpreadNotAllowed(
    variable_name~ : String,
    variable_type~ : String,
    location_type~ : String
  )
  DuplicateVariableDeclarations(variable_name~ : String)
  NullValueForNonNullVariable(variable_name~ : String, variable_type~ : String)
  ExpectingValueForNonNullableVariable(
    variable_name~ : String,
    variable_type~ : String
  )
  DuplicateFragmentDefinitions(fragment_name~ : String)
  DuplicateOperationDefinitions(operation_name~ : String)
  AnonymousOperationMustBeUnique
  NoMutationsAreDefined
  NoSubscriptionsAreDefined
  InternalSelectionRootIsNotObject
  OperationNotFound(operation_name~ : String)
  AnonymousOperationNotFound
  ArgumentsNotFound(
    type_name~ : String,
    field_name~ : String,
    argument_names~ : Array[String]
  )
  VArgumentNotFound(
    type_name~ : String,
    field_name~ : String,
    argument_name~ : String
  )
  DuplicateArguments(
    type_name~ : String,
    field_name~ : String,
    argument_name~ : String
  )
  RequiredArgumentNotFound(
    type_name~ : String,
    field_name~ : String,
    argument_name~ : String
  )
  FieldSelectionSetIsEmpty
  NotAValidName(String)
}

///|
pub fn ValidationError::display(self : ValidationError) -> String {
  match self {
    CycleDetected(path) => {
      let names = path.map(n => "Name(\"\{n}\")").join(", ")
      "fragment cycle detected through: [\{names}]"
    }
    UnknownFragment(n) => "fragment not defined in the document: \{n}"
    FragmentOnNonCompositeType(fragment_name~, type_name~) => {
      let what = match fragment_name {
        None => "inline fragment"
        Some(n) => "fragment \{n}"
      }
      "\{what} is defined on a non-composite type: \{type_name}"
    }
    FragmentCannotBeSpread(selection_type~, fragment_type~) =>
      "fragment of type \{fragment_type} cannot be spread on type \{selection_type}"
    NoFieldOnType(type_name~, field_name~) =>
      "no such field on type \{type_name}: \{field_name}"
    UnknownType(t) => "no such type defined in the document: \{t}"
    InternalTypeNotFound(type_name~) =>
      "an internal error occurred during validation: type lookup failed for \{type_name}"
    InternalNoFieldOnSubtype(type_name~, sub_type_name~, field_name~) =>
      "an internal error occurred during validation: field \{field_name} lookup failed for sub type '\{sub_type_name}' of type '\{type_name}'"
    FieldsConflictDifferentFields(nalias~, field1~, field2~) =>
      "different fields \{field1} and \{field2} cannot be merged under the same alias: \{nalias}"
    FieldsConflictDifferingTypes(nalias~, type1~, type2~) =>
      "fields of different type \{type1} and \{type2} cannot be merged under the same alias: \{nalias}"
    FieldsConflictDifferingArguments(nalias~) =>
      "cannot merge fields with different arguments on the same alias: \{nalias}"
    IncorrectFormat(expected_type~, actual_type~) =>
      "expected a value of type \{expected_type} but found a value of type \{actual_type}"
    UnexpectedNull(expected_type~) =>
      "a null value found when expected a value of not nullable type: \{expected_type}"
    InputFieldNotFound(type_name~, field_name~) =>
      "the field \{field_name} on type \{type_name} is not found"
    DuplicateInputFields(type_name~, field~) =>
      "the field \{field} on type \{type_name} is specified more than once"
    EnumValueNotFound(type_name~, enum_value~) =>
      "the enum value \{enum_value} on type \{type_name} is not found"
    NotInputType(variable_name~, type_name~) =>
      "the variable \{variable_name} is of type \{type_name} which is not an input type"
    InternalNotInputType(type_name~, actual_type~) =>
      "an internal error occurred: expected \{type_name} to be an input type but is of \{actual_type}"
    VariableNotDefined(variable_name~) =>
      "the variable \{variable_name} is not defined in the document"
    VariableSpreadNotAllowed(variable_name~, variable_type~, location_type~) =>
      "the variable \{variable_name} of type \{variable_type} cannot be used at a location of type \{location_type}"
    DuplicateVariableDeclarations(variable_name~) =>
      "the following variable is defined more than once: \{variable_name}"
    NullValueForNonNullVariable(variable_name~, variable_type~) =>
      "null value provided for non-nullable variable \{variable_name} of type \{variable_type}"
    ExpectingValueForNonNullableVariable(variable_name~, variable_type~) =>
      "expected a value for non-nullable variable \{variable_name} of type \{variable_type} but no value was provided"
    DuplicateFragmentDefinitions(fragment_name~) =>
      "the following fragment is defined more than once: \{fragment_name}"
    DuplicateOperationDefinitions(operation_name~) =>
      "the following operation is defined more than once: \{operation_name}"
    AnonymousOperationMustBeUnique =>
      "there should only be one anonymous operation in the document"
    NoMutationsAreDefined => "no mutations are defined in the schema"
    NoSubscriptionsAreDefined => "no subscriptions are defined in the schema"
    InternalSelectionRootIsNotObject =>
      "internal error: selection root is not of object type"
    OperationNotFound(operation_name~) =>
      "operation not found: \{operation_name}"
    AnonymousOperationNotFound => "no anonymous operation found in the document"
    ArgumentsNotFound(type_name~, field_name~, argument_names~) => {
      let names = argument_names.join(", ")
      "expected arguments '\{names}' on field \{field_name} of type \{type_name} are not found"
    }
    VArgumentNotFound(type_name~, field_name~, argument_name~) =>
      "argument \{argument_name} on field \{field_name} of type \{type_name} not found"
    DuplicateArguments(type_name~, field_name~, argument_name~) =>
      "argument \{argument_name} on field \{field_name} of type \{type_name} is defined more than once"
    RequiredArgumentNotFound(type_name~, field_name~, argument_name~) =>
      "required argument \{argument_name} not found on field \{field_name} of type \{type_name}"
    FieldSelectionSetIsEmpty => "no fields are selected"
    NotAValidName(s) =>
      "the string \{s} in the provided json value is not a valid GraphQL name"
  }
}

///|
/// GraphQL 型の表示 (`[String!]!` 形式)。エラーメッセージ用
pub fn gtype_display(t : @graphql.GType) -> String {
  let base = match t.base {
    Named(n) => n.as_str()
    List(inner) => "[" + gtype_display(inner) + "]"
  }
  if t.nullable {
    base
  } else {
    base + "!"
  }
}
