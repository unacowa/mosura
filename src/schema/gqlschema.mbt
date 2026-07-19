// lang-graphql/src/schema.rs の移植 (SchemaContext を具象化)

///|
pub(all) enum DeprecationStatus {
  NotDeprecated
  Deprecated(reason~ : String?)
} derive(Eq, Debug)

///|
pub fn DeprecationStatus::is_deprecated(self : DeprecationStatus) -> Bool {
  self is Deprecated(..)
}

///|
pub fn DeprecationStatus::reason(self : DeprecationStatus) -> String? {
  match self {
    NotDeprecated => None
    Deprecated(reason~) => reason
  }
}

///|
/// スキーマに付与されるディレクティブ (SDL 由来)
pub(all) struct SDirective {
  name : @graphql.Name
  arguments : @sorted_map.SortedMap[@graphql.Name, @graphql.ConstValue]
}

///|
/// オブジェクト型
pub(all) struct SObject {
  name : @graphql.TypeName
  description : String?
  fields : @sorted_map.SortedMap[@graphql.Name, Namespaced[SField]]
  interfaces : @sorted_map.SortedMap[@graphql.TypeName, Namespaced[Unit]]
  directives : Array[SDirective]
}

///|
/// フィールド定義
pub(all) struct SField {
  name : @graphql.Name
  description : String?
  info : Annotation
  field_type : @graphql.GType
  arguments : @sorted_map.SortedMap[@graphql.Name, Namespaced[SInputField]]
  deprecation_status : DeprecationStatus
}

///|
/// 入力フィールド / 引数定義
pub(all) struct SInputField {
  name : @graphql.Name
  description : String?
  info : Annotation
  field_type : @graphql.GType
  default_value : @graphql.ConstValue?
  deprecation_status : DeprecationStatus
}

///|
/// 入力オブジェクト型
pub(all) struct SInputObject {
  name : @graphql.TypeName
  description : String?
  fields : @sorted_map.SortedMap[@graphql.Name, Namespaced[SInputField]]
  directives : Array[SDirective]
}

///|
/// スカラー型
pub(all) struct SScalar {
  name : @graphql.TypeName
  description : String?
  directives : Array[SDirective]
}

///|
/// enum 値
pub(all) struct SEnumValue {
  value : @graphql.Name
  description : String?
  deprecation_status : DeprecationStatus
  info : Annotation
}

///|
/// enum 型
pub(all) struct SEnum {
  name : @graphql.TypeName
  description : String?
  values : @sorted_map.SortedMap[@graphql.Name, Namespaced[SEnumValue]]
  directives : Array[SDirective]
}

///|
/// union 型
pub(all) struct SUnion {
  name : @graphql.TypeName
  description : String?
  fields : @sorted_map.SortedMap[@graphql.Name, Namespaced[SField]]
  members : @sorted_map.SortedMap[@graphql.TypeName, Namespaced[Unit]]
  directives : Array[SDirective]
}

///|
/// interface 型
pub(all) struct SInterface {
  name : @graphql.TypeName
  description : String?
  fields : @sorted_map.SortedMap[@graphql.Name, Namespaced[SField]]
  interfaces : @sorted_map.SortedMap[@graphql.TypeName, Namespaced[Unit]]
  implemented_by : @sorted_map.SortedMap[@graphql.TypeName, Namespaced[Unit]]
  directives : Array[SDirective]
}

///|
pub(all) enum TypeInfo {
  Scalar(SScalar)
  Enum(SEnum)
  Object(SObject)
  Interface(SInterface)
  Union(SUnion)
  InputObject(SInputObject)
}

///|
pub fn TypeInfo::kind(self : TypeInfo) -> String {
  match self {
    Scalar(_) => "SCALAR"
    Enum(_) => "ENUM"
    Interface(_) => "INTERFACE"
    Object(_) => "OBJECT"
    Union(_) => "UNION"
    InputObject(_) => "INPUT_OBJECT"
  }
}

///|
pub fn TypeInfo::type_name(self : TypeInfo) -> @graphql.TypeName {
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
/// 入力位置で使える型 (Scalar / Enum / InputObject)
pub(all) enum InputType {
  InScalar(SScalar)
  InEnum(SEnum)
  InInputObject(SInputObject)
}

///|
pub fn TypeInfo::as_input_type(self : TypeInfo) -> InputType? {
  match self {
    Scalar(info) => Some(InScalar(info))
    Enum(info) => Some(InEnum(info))
    InputObject(info) => Some(InInputObject(info))
    Interface(_) | Object(_) | Union(_) => None
  }
}

///|
/// GraphQL スキーマ本体
pub(all) struct Schema {
  types : @sorted_map.SortedMap[@graphql.TypeName, TypeInfo]
  query_type : @graphql.TypeName
  mutation_type : @graphql.TypeName?
  subscription_type : @graphql.TypeName?
  namespaces : Array[String]
}

///|
pub fn Schema::get_type(
  self : Schema,
  type_name : @graphql.TypeName,
) -> TypeInfo? {
  self.types.get(type_name)
}

///|
/// __typename フィールド (全オブジェクト型に自動追加される)
pub fn build_typename_field() -> Namespaced[SField] {
  allow_all_namespaced(SField::{
    name: @graphql.Name::new_unchecked("__typename"),
    description: None,
    info: Introspection,
    field_type: {
      base: Named(@graphql.TypeName(@graphql.Name::new_unchecked("String"))),
      nullable: false,
    },
    arguments: @sorted_map.SortedMap([]),
    deprecation_status: NotDeprecated,
  })
}
