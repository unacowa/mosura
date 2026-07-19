// lang-graphql/src/ast/value.rs の移植

///|
/// リーフ値
pub(all) enum SimpleValue {
  Null
  Id(String)
  Integer(Int64)
  Float(Double)
  SVString(String)
  Boolean(Bool)
  SVEnum(Name)
} derive(Eq)

///|
pub(all) struct KeyValue[V] {
  key : Spanning[Name]
  value : Spanning[V]
} derive(Eq)

///|
/// 変数を含まない値
pub(all) enum ConstValue {
  SimpleValue(SimpleValue)
  List(Array[Spanning[ConstValue]])
  Object(Array[Spanning[KeyValue[ConstValue]]])
} derive(Eq)

///|
/// 変数を含みうる値
pub(all) enum Value {
  Variable(Name)
  SimpleValue(SimpleValue)
  List(Array[Spanning[Value]])
  Object(Array[Spanning[KeyValue[Value]]])
} derive(Eq)

///|
pub fn SimpleValue::to_json(self : SimpleValue) -> Json {
  match self {
    Null => Json::null()
    Id(id) => Json::string(id)
    Integer(i) => Json::number(i.to_double())
    Float(f) => Json::number(f)
    SVString(s) => Json::string(s)
    Boolean(b) => Json::boolean(b)
    SVEnum(e) => Json::string(e.as_str())
  }
}

///|
pub fn ConstValue::to_json(self : ConstValue) -> Json {
  match self {
    SimpleValue(v) => v.to_json()
    List(l) => Json::array(l.map(i => i.item.to_json()))
    Object(o) => {
      let m : Map[String, Json] = Map([])
      for kv in o {
        m[kv.item.key.item.as_str()] = kv.item.value.item.to_json()
      }
      Json::object(m)
    }
  }
}

///|
pub fn ConstValue::kind(self : ConstValue) -> String {
  match self {
    SimpleValue(v) =>
      match v {
        Null => "NULL"
        Id(_) => "ID"
        Integer(_) => "INTEGER"
        Float(_) => "FLOAT"
        SVString(_) => "STRING"
        Boolean(_) => "BOOLEAN"
        SVEnum(_) => "ENUM"
      }
    List(_) => "LIST"
    Object(_) => "OBJECT"
  }
}
