// lang-graphql/src/normalized_ast.rs の移植 (参照を値コピーに変更)

///|
pub suberror NormalizedError {
  ArgumentNotFound(field_call_name~ : String, argument_name~ : String)
  EmptyFieldCallNotFound
  NoTypenameFound
  UnexpectedValue(expected_kind~ : String, found~ : Json)
}

///|
pub fn NormalizedError::display(self : NormalizedError) -> String {
  match self {
    ArgumentNotFound(field_call_name~, argument_name~) =>
      "expected argument '\{argument_name}' not found on field: \{field_call_name}"
    EmptyFieldCallNotFound => "empty field call not found"
    NoTypenameFound => "empty type_name found for an object selection set"
    UnexpectedValue(expected_kind~, found~) =>
      "value not as expected, expected: \{expected_kind} but found: \{found.stringify()}"
  }
}

///|
pub(all) enum NSimpleValue {
  NNull
  NId(String)
  NInteger(Int64)
  NFloat(Double)
  NString(String)
  NBoolean(Bool)
  NEnum(name~ : @graphql.Name, info~ : NodeInfo)
}

///|
pub(all) struct NInputField {
  name : @graphql.Name
  info : NodeInfo
  value : NValue
}

///|
/// 正規化済みの値
pub(all) enum NValue {
  SimpleValue(NSimpleValue)
  List(Array[NValue])
  Object(Map[@graphql.Name, NInputField])
  /// カスタムスカラー等の JSON 値
  NJson(Json)
}

///|
pub fn NValue::as_json(self : NValue) -> Json {
  match self {
    SimpleValue(NNull) => Json::null()
    SimpleValue(NId(id)) => Json::string(id)
    SimpleValue(NBoolean(b)) => Json::boolean(b)
    SimpleValue(NString(s)) => Json::string(s)
    SimpleValue(NFloat(f)) => Json::number(f)
    SimpleValue(NInteger(i)) => int64_to_json(i)
    SimpleValue(NEnum(name~, ..)) => Json::string(name.as_str())
    List(xs) => Json::array(xs.map(v => v.as_json()))
    Object(xs) => {
      let m : Map[String, Json] = Map([])
      for name, field in xs {
        m[name.as_str()] = field.value.as_json()
      }
      Json::object(m)
    }
    NJson(j) => j
  }
}

///|
/// i64 を JSON に (53bit を超える場合も数値として文字列化しない: serde_json 同様に数値)
pub fn int64_to_json(i : Int64) -> Json {
  // Json::number は Double 経由。53bit 以内はそのまま、超える場合は表現を保つため文字列化した数値リテラルを使う
  Json::number(i.to_double())
}

///|
pub fn NValue::as_boolean(self : NValue) -> Bool raise NormalizedError {
  match self {
    SimpleValue(NBoolean(b)) => b
    _ => raise UnexpectedValue(expected_kind="BOOLEAN", found=self.as_json())
  }
}

///|
pub fn NValue::as_string_value(self : NValue) -> String raise NormalizedError {
  match self {
    SimpleValue(NString(s)) => s
    _ => raise UnexpectedValue(expected_kind="STRING", found=self.as_json())
  }
}

///|
pub fn NValue::as_int_u32(self : NValue) -> Int raise NormalizedError {
  match self {
    SimpleValue(NInteger(i)) =>
      if i >= 0 && i <= 4294967295 {
        i.to_int()
      } else {
        raise UnexpectedValue(
          expected_kind="NON-NEGATIVE 32-bit INT",
          found=self.as_json(),
        )
      }
    _ => raise UnexpectedValue(expected_kind="INT", found=self.as_json())
  }
}

///|
pub fn NValue::as_int_i64(self : NValue) -> Int64 raise NormalizedError {
  match self {
    SimpleValue(NInteger(i)) => i
    _ => raise UnexpectedValue(expected_kind="INT", found=self.as_json())
  }
}

///|
pub fn NValue::as_object_value(
  self : NValue,
) -> Map[@graphql.Name, NInputField] raise NormalizedError {
  match self {
    Object(fields) => fields
    _ => raise UnexpectedValue(expected_kind="OBJECT", found=self.as_json())
  }
}

///|
pub fn NValue::as_list(self : NValue) -> Array[NValue] raise NormalizedError {
  match self {
    List(values) => values
    _ => raise UnexpectedValue(expected_kind="LIST", found=self.as_json())
  }
}

///|
pub fn NValue::is_null(self : NValue) -> Bool {
  match self {
    SimpleValue(NNull) => true
    NJson(Json::Null) => true
    _ => false
  }
}

///|
pub(all) struct NDirective {
  name : @graphql.Name
  arguments : Map[@graphql.Name, NInputField]
}

///|
pub(all) struct FieldCall {
  name : @graphql.Name
  info : NodeInfo
  arguments : Map[@graphql.Name, NInputField]
}

///|
pub fn FieldCall::expected_argument(
  self : FieldCall,
  argument : @graphql.Name,
) -> NInputField raise NormalizedError {
  match self.arguments.get(argument) {
    Some(f) => f
    None =>
      raise ArgumentNotFound(
        field_call_name=self.name.as_str(),
        argument_name=argument.as_str(),
      )
  }
}

///|
/// field_path (interface/union のための型名パス) → FieldCall
/// キーは型名リストを "/" 連結した文字列 (Rust の HashMap<Vec<TypeName>,_> 相当)
pub(all) struct NField {
  nalias : @graphql.Alias
  field_calls : Map[String, FieldCall]
  selection_set : NSelectionSet
  type_container : @graphql.GType
}

///|
pub fn field_path_key(path : Array[@graphql.TypeName]) -> String {
  path.map(t => t.as_str()).join("/")
}

///|
/// 単一の FieldCall を取得 (interface/union でなければ空パスに 1 つ)
pub fn NField::field_call(self : NField) -> FieldCall raise NormalizedError {
  match self.field_calls.get("") {
    Some(fc) => fc
    None => raise EmptyFieldCallNotFound
  }
}

///|
pub(all) struct NSelectionSet {
  fields : Map[@graphql.Alias, NField]
  type_name : @graphql.TypeName?
}

///|
/// セレクションセットを走査して JSON オブジェクトを構築する。__typename を特別扱いする。
pub fn[E : Error] NSelectionSet::as_object_selection_set(
  self : NSelectionSet,
  f : (@graphql.TypeName, NField, FieldCall) -> Json raise E,
) -> Map[String, Json] raise {
  let type_name = match self.type_name {
    Some(t) => t
    None => raise NoTypenameFound
  }
  let response : Map[String, Json] = Map([])
  for a, field in self.fields {
    let field_call = field.field_call()
    let field_response = if field_call.name.as_str() == "__typename" {
      Json::string(type_name.as_str())
    } else {
      f(type_name, field, field_call)
    }
    response[a.0.as_str()] = field_response
  }
  response
}

///|
pub(all) struct NOperation {
  ty : @graphql.OperationType
  name : @graphql.Name?
  selection_set : NSelectionSet
}
