// graphql-types/src/lib.rs の移植 (Name, TypeName, Alias, OperationType, TypeContainer)

///|
/// 妥当な GraphQL 名 (/[_A-Za-z][_0-9A-Za-z]*/)
pub(all) struct Name {
  name : String
} derive(Eq, Compare, Hash)

///|
pub fn Name::as_str(self : Name) -> String {
  self.name
}

///|
fn match_first(c : Char) -> Bool {
  c == '_' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
}

///|
fn match_body(c : Char) -> Bool {
  match_first(c) || (c >= '0' && c <= '9')
}

///|
pub fn is_valid_graphql_name(text : String) -> Bool {
  match text.view() {
    [first, .. body] =>
      match_first(first) && body.iter().all(c => match_body(c))
    [] => false
  }
}

///|
pub suberror InvalidGraphQlName {
  InvalidGraphQlName(String)
} derive(Debug)

///|
pub fn Name::new(s : String) -> Name raise InvalidGraphQlName {
  if is_valid_graphql_name(s) {
    { name: s }
  } else {
    raise InvalidGraphQlName(s)
  }
}

///|
/// バリデーション済み文字列から作る (lexer 内部用)
pub fn Name::new_unchecked(s : String) -> Name {
  { name: s }
}

///|
/// GraphQL 型名
pub(all) struct TypeName(Name) derive(Eq, Compare, Hash)

///|
pub fn TypeName::as_str(self : TypeName) -> String {
  self.0.as_str()
}

///|
/// フィールドエイリアス
pub(all) struct Alias(Name) derive(Eq, Hash)

///|
pub fn Alias::new(name : Name) -> Alias {
  Alias(name)
}

///|
/// オペレーション種別
pub(all) enum OperationType {
  Query
  Mutation
  Subscription
} derive(Eq, Hash)

///|
pub fn OperationType::as_str(self : OperationType) -> String {
  match self {
    Query => "query"
    Mutation => "mutation"
    Subscription => "subscription"
  }
}

///|
/// GraphQL の型。例: `String` `[String!]!`
pub(all) struct TypeContainer[T] {
  base : BaseTypeContainer[T]
  nullable : Bool
} derive(Eq, Hash)

///|
/// null 可否を除いたベース型
pub(all) enum BaseTypeContainer[T] {
  Named(T)
  List(TypeContainer[T])
} derive(Eq, Hash)

///|
pub type GType = TypeContainer[TypeName]

///|
pub type BaseType = BaseTypeContainer[TypeName]

///|
pub fn[T] TypeContainer::named_non_null(named : T) -> TypeContainer[T] {
  { base: Named(named), nullable: false }
}

///|
pub fn[T] TypeContainer::named_null(named : T) -> TypeContainer[T] {
  { base: Named(named), nullable: true }
}

///|
pub fn[T] TypeContainer::list_null(
  element_type : TypeContainer[T],
) -> TypeContainer[T] {
  { base: List(element_type), nullable: true }
}

///|
pub fn[T] TypeContainer::list_non_null(
  element_type : TypeContainer[T],
) -> TypeContainer[T] {
  { base: List(element_type), nullable: false }
}

///|
pub fn[T] TypeContainer::underlying_type(self : TypeContainer[T]) -> T {
  match self.base {
    Named(n) => n
    List(ty) => ty.underlying_type()
  }
}

///|
pub fn[T] TypeContainer::is_list(self : TypeContainer[T]) -> Bool {
  match self.base {
    Named(_) => false
    List(_) => true
  }
}

///|
pub fn[T] TypeContainer::list_dimensions(self : TypeContainer[T]) -> Int {
  match self.base {
    Named(_) => 0
    List(ty) => 1 + ty.list_dimensions()
  }
}
