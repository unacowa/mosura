// lang-graphql/src/ast/schema.rs の移植 (SDL の AST)

///|
/// GraphQL サービスを定義するドキュメント (SDL)
pub(all) struct SchemaDocument {
  definitions : Array[Spanning[TypeSystemDefinition]]
} derive(Eq)

///|
pub(all) enum TypeSystemDefinition {
  Schema(SchemaDefinition)
  Type(TypeDefinition)
  Directive(DirectiveDefinition)
} derive(Eq)

///|
/// const 値のみを引数に取るディレクティブ
pub(all) struct ConstDirective {
  name : Spanning[Name]
  arguments : Spanning[Array[ConstArgument]]?
} derive(Eq)

///|
pub type ConstArgument = Spanning[KeyValue[ConstValue]]

///|
pub(all) struct SchemaDefinition {
  is_extension : Bool
  description : Spanning[String]?
  directives : Array[Spanning[ConstDirective]]
  operation_types : Array[Spanning[(Spanning[OperationType], Spanning[Name])]]
} derive(Eq)

///|
pub(all) enum TypeDefinition {
  Scalar(ScalarTypeDefinition)
  Enum(EnumTypeDefinition)
  Object(ObjectTypeDefinition)
  Interface(InterfaceTypeDefinition)
  Union(UnionTypeDefinition)
  InputObject(InputObjectTypeDefinition)
} derive(Eq)

///|
pub fn TypeDefinition::name(self : TypeDefinition) -> Spanning[Name] {
  match self {
    Scalar(d) => d.name
    Enum(d) => d.name
    Object(d) => d.name
    Interface(d) => d.name
    Union(d) => d.name
    InputObject(d) => d.name
  }
}

///|
pub(all) struct ScalarTypeDefinition {
  is_extension : Bool
  description : Spanning[String]?
  name : Spanning[Name]
  directives : Array[Spanning[ConstDirective]]
} derive(Eq)

///|
pub(all) struct EnumValueDefinition {
  description : Spanning[String]?
  value : Spanning[Name]
  directives : Array[Spanning[ConstDirective]]
} derive(Eq)

///|
pub(all) struct EnumTypeDefinition {
  is_extension : Bool
  description : Spanning[String]?
  name : Spanning[Name]
  directives : Array[Spanning[ConstDirective]]
  values : Array[Spanning[EnumValueDefinition]]
} derive(Eq)

///|
pub(all) struct ObjectTypeDefinition {
  is_extension : Bool
  description : Spanning[String]?
  name : Spanning[Name]
  directives : Array[Spanning[ConstDirective]]
  implements : Array[Spanning[Name]]
  fields : Array[Spanning[FieldDefinition]]
} derive(Eq)

///|
pub(all) struct InterfaceTypeDefinition {
  is_extension : Bool
  description : Spanning[String]?
  name : Spanning[Name]
  directives : Array[Spanning[ConstDirective]]
  implements : Array[Spanning[Name]]
  fields : Array[Spanning[FieldDefinition]]
} derive(Eq)

///|
pub(all) struct UnionTypeDefinition {
  is_extension : Bool
  description : Spanning[String]?
  name : Spanning[Name]
  directives : Array[Spanning[ConstDirective]]
  members : Array[Spanning[Name]]
} derive(Eq)

///|
pub(all) struct InputObjectTypeDefinition {
  is_extension : Bool
  description : Spanning[String]?
  name : Spanning[Name]
  directives : Array[Spanning[ConstDirective]]
  fields : Array[Spanning[InputValueDefinition]]
} derive(Eq)

///|
pub(all) struct FieldDefinition {
  description : Spanning[String]?
  name : Spanning[Name]
  arguments : Array[Spanning[InputValueDefinition]]
  ty : Spanning[GType]
  directives : Array[Spanning[ConstDirective]]
} derive(Eq)

///|
pub(all) struct InputValueDefinition {
  description : Spanning[String]?
  name : Spanning[Name]
  ty : Spanning[GType]
  default_value : Spanning[ConstValue]?
  directives : Array[Spanning[ConstDirective]]
} derive(Eq)

///|
pub(all) struct DirectiveDefinition {
  description : Spanning[String]?
  name : Spanning[Name]
  arguments : Array[Spanning[InputValueDefinition]]
  locations : Array[Spanning[DirectiveLocation]]
} derive(Eq)

///|
pub(all) enum DirectiveLocation {
  Query
  Mutation
  Subscription
  Field
  FragmentDefinition
  FragmentSpread
  InlineFragment
  Schema
  Scalar
  Object
  FieldDefinition
  ArgumentDefinition
  Interface
  Union
  Enum
  EnumValue
  InputObject
  InputFieldDefinition
  VariableDefinition
} derive(Eq)
