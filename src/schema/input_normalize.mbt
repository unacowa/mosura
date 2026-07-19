// lang-graphql/src/validation/input/{normalize,source,value,const_value,json_value}.rs の移植。
// ValueSource trait は InValue enum + match に置き換えた (意味は同一)。

///|
/// 値の出所 (実行可能ドキュメントの値 / const 値 / リクエスト変数の JSON)
pub(all) enum InValue {
  VGql(@graphql.Value)
  VConst(@graphql.ConstValue)
  VJson(Json)
}

///|
/// 値が置かれる位置の型情報
pub(all) struct LocationType {
  ty : @graphql.GType
  default_value : @graphql.ConstValue?
}

///|
fn InValue::kind(self : InValue) -> String {
  match self {
    VGql(v) =>
      match v {
        Variable(_) => "VARIABLE"
        SimpleValue(sv) => simple_value_kind(sv)
        List(_) => "LIST"
        Object(_) => "OBJECT"
      }
    VConst(v) =>
      match v {
        SimpleValue(sv) => simple_value_kind(sv)
        List(_) => "LIST"
        Object(_) => "OBJECT"
      }
    VJson(j) =>
      match j {
        Json::Null => "NULL"
        Json::True | Json::False => "BOOLEAN"
        Json::Number(_, ..) => "NUMBER"
        Json::String(_) => "STRING"
        Json::Array(_) => "ARRAY"
        Json::Object(_) => "OBJECT"
      }
  }
}

///|
fn simple_value_kind(sv : @graphql.SimpleValue) -> String {
  match sv {
    Null => "NULL"
    Id(_) => "ID"
    Integer(_) => "INTEGER"
    Float(_) => "FLOAT"
    SVString(_) => "STRING"
    Boolean(_) => "BOOLEAN"
    SVEnum(_) => "ENUM"
  }
}

///|
fn InValue::is_null(self : InValue) -> Bool {
  match self {
    VGql(SimpleValue(Null)) => true
    VConst(SimpleValue(Null)) => true
    VJson(Json::Null) => true
    _ => false
  }
}

///|
fn InValue::is_list(self : InValue) -> Bool {
  match self {
    // 変数は spread され得るため true (value.rs と同じ)
    VGql(Variable(_)) => true
    VGql(List(_)) => true
    VConst(List(_)) => true
    VJson(Json::Array(_)) => true
    _ => false
  }
}

///|
fn json_as_i64(j : Json) -> Int64? {
  match j {
    Json::Number(d, repr~) =>
      // repr があれば整数リテラルとして解釈を試みる
      match repr {
        Some(r) =>
          Some(@string.parse_int64(r)) catch {
            // "1.0" 等は i64 でない
            _ =>
              if d == d.floor() && d.abs() <= 9007199254740992.0 {
                Some(d.to_int64())
              } else {
                None
              }
          }
        None =>
          if d == d.floor() && d.abs() <= 9007199254740992.0 {
            Some(d.to_int64())
          } else {
            None
          }
      }
    _ => None
  }
}

///|
/// 値を JSON にする (変数はコンテキストから解決)
fn InValue::to_raw_json(
  self : InValue,
  ctx : NormalizeCtx,
  location_type : LocationType,
) -> Json raise ValidationError {
  match self {
    VJson(j) => j
    VConst(v) => v.to_json()
    VGql(v) =>
      match v {
        Variable(name) => ctx.resolve_variable(location_type, name).as_json()
        SimpleValue(sv) => sv.to_json()
        List(l) => {
          let items = []
          for i in l {
            items.push(InValue::VGql(i.item).to_raw_json(ctx, location_type))
          }
          Json::array(items)
        }
        Object(o) => {
          let m : Map[String, Json] = Map([])
          for kv in o {
            m[kv.item.key.item.as_str()] = InValue::VGql(kv.item.value.item).to_raw_json(
              ctx, location_type,
            )
          }
          Json::object(m)
        }
      }
  }
}

///|
/// 正規化のコンテキスト (スキーマ + ロール + 変数)
pub(all) struct NormalizeCtx {
  schema : Schema
  ns : NamespaceCtx
  variables : Variables?
}

///|
fn NormalizeCtx::resolve_variable(
  self : NormalizeCtx,
  location_type : LocationType,
  name : @graphql.Name,
) -> NValue raise ValidationError {
  match self.variables {
    Some(vars) => vars.get(self, location_type, name)
    None => raise VariableNotDefined(variable_name=name.as_str())
  }
}

///|
/// 入力値の正規化 (input/normalize.rs::normalize)
pub fn normalize_input(
  ctx : NormalizeCtx,
  value : InValue,
  location_type : LocationType,
  type_info : InputType,
) -> NValue raise ValidationError {
  let normalized_value : NValue = match location_type.ty.base {
    Named(_) => {
      if value.is_null() && location_type.ty.nullable {
        return SimpleValue(NNull)
      }
      match type_info {
        InScalar(scalar) =>
          normalize_scalar_value(ctx, location_type, value, scalar)
        InEnum(enum_info) =>
          normalize_enum_value(ctx, location_type, value, enum_info)
        InInputObject(input_object) =>
          normalize_input_object(ctx, location_type, value, input_object)
      }
    }
    List(wrapped_type) =>
      if value.is_null() {
        SimpleValue(NNull)
      } else if value.is_list() {
        normalize_list_value(ctx, location_type, wrapped_type, value, type_info)
      } else {
        // リストでない値は次元数分ネストしたリストに強制する
        let expected_list_type_dimensions = wrapped_type.list_dimensions() + 1
        let expected_base_type = underlying_type_container(location_type.ty)
        let normalized_value = normalize_input(
          ctx,
          value,
          { ty: expected_base_type, default_value: None },
          type_info,
        )
        create_nested_list(expected_list_type_dimensions, normalized_value)
      }
  }
  if !location_type.ty.nullable && normalized_value.is_null() {
    raise UnexpectedNull(expected_type=gtype_display(location_type.ty))
  }
  normalized_value
}

///|
fn underlying_type_container(t : @graphql.GType) -> @graphql.GType {
  match t.base {
    Named(_) => t
    List(inner) => underlying_type_container(inner)
  }
}

///|
fn create_nested_list(dimension : Int, value : NValue) -> NValue {
  let mut current = value
  for _ in 0..<dimension {
    current = NValue::List([current])
  }
  current
}

///|
fn normalize_list_value(
  ctx : NormalizeCtx,
  location_type : LocationType,
  wrapped_type : @graphql.GType,
  value : InValue,
  type_info : InputType,
) -> NValue raise ValidationError {
  // 変数の場合は変数値を解決して返す
  match value {
    VGql(Variable(name)) => return ctx.resolve_variable(location_type, name)
    _ => ()
  }
  let items : Array[InValue] = match value {
    VGql(List(l)) => l.map(i => InValue::VGql(i.item))
    VConst(List(l)) => l.map(i => InValue::VConst(i.item))
    VJson(Json::Array(l)) => l.map(j => InValue::VJson(j))
    _ => raise IncorrectFormat(expected_type="LIST", actual_type=value.kind())
  }
  let accum : Array[NValue] = []
  for v in items {
    // リストの正規化中はリストへの強制をしない
    // ([[Int]] に [1,2] は不正、[Int] に 1 は妥当)
    if wrapped_type.is_list() && !v.is_list() {
      raise IncorrectFormat(expected_type="LIST", actual_type=value.kind())
    }
    accum.push(
      normalize_input(
        ctx,
        v,
        { ty: wrapped_type, default_value: None },
        type_info,
      ),
    )
  }
  NValue::List(accum)
}

///|
fn normalize_scalar_value(
  ctx : NormalizeCtx,
  location_type : LocationType,
  value : InValue,
  scalar : SScalar,
) -> NValue raise ValidationError {
  // 変数参照はまず解決する
  match value {
    VGql(Variable(name)) => return ctx.resolve_variable(location_type, name)
    _ => ()
  }
  match scalar.name.as_str() {
    "Int" =>
      match value {
        VGql(SimpleValue(Integer(i))) | VConst(SimpleValue(Integer(i))) =>
          SimpleValue(NInteger(i))
        VJson(j) =>
          match json_as_i64(j) {
            Some(i) => SimpleValue(NInteger(i))
            None =>
              raise IncorrectFormat(
                expected_type="NUMBER",
                actual_type=value.kind(),
              )
          }
        _ =>
          raise IncorrectFormat(
            expected_type="INTEGER",
            actual_type=value.kind(),
          )
      }
    "ID" =>
      match value {
        VGql(SimpleValue(SVString(s))) | VConst(SimpleValue(SVString(s))) =>
          SimpleValue(NId(s))
        VJson(Json::String(s)) => SimpleValue(NId(s))
        _ => raise IncorrectFormat(expected_type="ID", actual_type=value.kind())
      }
    "Float" =>
      match value {
        VGql(SimpleValue(Float(f))) | VConst(SimpleValue(Float(f))) =>
          SimpleValue(NFloat(f))
        VGql(SimpleValue(Integer(i))) | VConst(SimpleValue(Integer(i))) =>
          SimpleValue(NFloat(i.to_double()))
        VJson(Json::Number(d, ..)) => SimpleValue(NFloat(d))
        _ =>
          raise IncorrectFormat(expected_type="FLOAT", actual_type=value.kind())
      }
    "Boolean" =>
      match value {
        VGql(SimpleValue(Boolean(b))) | VConst(SimpleValue(Boolean(b))) =>
          SimpleValue(NBoolean(b))
        VJson(Json::True) => SimpleValue(NBoolean(true))
        VJson(Json::False) => SimpleValue(NBoolean(false))
        _ =>
          raise IncorrectFormat(
            expected_type="BOOLEAN",
            actual_type=value.kind(),
          )
      }
    "String" =>
      match value {
        VGql(SimpleValue(SVString(s))) | VConst(SimpleValue(SVString(s))) =>
          SimpleValue(NString(s))
        VJson(Json::String(s)) => SimpleValue(NString(s))
        _ =>
          raise IncorrectFormat(
            expected_type="STRING",
            actual_type=value.kind(),
          )
      }
    // カスタムスカラーは JSON として受ける
    _ => NJson(value.to_raw_json(ctx, location_type))
  }
}

///|
fn normalize_enum_value(
  ctx : NormalizeCtx,
  location_type : LocationType,
  value : InValue,
  enum_info : SEnum,
) -> NValue raise ValidationError {
  let raw_name : @graphql.Name = match value {
    VGql(Variable(name)) => return ctx.resolve_variable(location_type, name)
    VGql(SimpleValue(SVEnum(e))) => e
    VConst(SimpleValue(SVEnum(e))) => e
    VJson(Json::String(s)) =>
      if @graphql.is_valid_graphql_name(s) {
        @graphql.Name::new_unchecked(s)
      } else {
        raise NotAValidName(s)
      }
    _ => raise IncorrectFormat(expected_type="ENUM", actual_type=value.kind())
  }
  match enum_info.values.get(raw_name) {
    Some(namespaced_value) =>
      match ctx.ns.get(namespaced_value) {
        Some((ev, namespaced)) =>
          SimpleValue(
            NEnum(name=raw_name, info={ generic: ev.info, namespaced }),
          )
        None =>
          raise EnumValueNotFound(
            type_name=enum_info.name.as_str(),
            enum_value=raw_name.as_str(),
          )
      }
    None =>
      raise EnumValueNotFound(
        type_name=enum_info.name.as_str(),
        enum_value=raw_name.as_str(),
      )
  }
}

///|
fn normalize_input_object(
  ctx : NormalizeCtx,
  location_type : LocationType,
  value : InValue,
  input_object : SInputObject,
) -> NValue raise ValidationError {
  // 変数参照はまず解決
  match value {
    VGql(Variable(name)) => return ctx.resolve_variable(location_type, name)
    _ => ()
  }
  let pairs : Array[(@graphql.Name, InValue)] = match value {
    VGql(Object(o)) =>
      o.map(kv => (kv.item.key.item, InValue::VGql(kv.item.value.item)))
    VConst(Object(o)) =>
      o.map(kv => (kv.item.key.item, InValue::VConst(kv.item.value.item)))
    VJson(Json::Object(o)) => {
      let acc = []
      for k, v in o {
        if @graphql.is_valid_graphql_name(k) {
          acc.push((@graphql.Name::new_unchecked(k), InValue::VJson(v)))
        } else {
          raise NotAValidName(k)
        }
      }
      acc
    }
    _ => raise IncorrectFormat(expected_type="OBJECT", actual_type=value.kind())
  }
  let normalized_object : Map[@graphql.Name, NInputField] = Map([])
  for pair in pairs {
    let (field, field_value) = pair
    let ns_field = match input_object.fields.get(field) {
      Some(f) => f
      None =>
        raise InputFieldNotFound(
          type_name=input_object.name.as_str(),
          field_name=field.as_str(),
        )
    }
    let (field_info, namespaced) = match ctx.ns.get(ns_field) {
      Some(x) => x
      None =>
        raise InputFieldNotFound(
          type_name=input_object.name.as_str(),
          field_name=field.as_str(),
        )
    }
    let field_type = field_info.field_type
    let field_type_info = lookup_input_type(ctx.schema, field_type)
    let normalized_field_value = normalize_input(
      ctx,
      field_value,
      { ty: field_type, default_value: field_info.default_value },
      field_type_info,
    )
    let normalized_input_field = NInputField::{
      name: field,
      info: { generic: field_info.info, namespaced },
      value: normalized_field_value,
    }
    if normalized_object.contains(field) {
      raise DuplicateInputFields(
        type_name=underlying_type_name(field_type).as_str(),
        field=field.as_str(),
      )
    }
    normalized_object[field] = normalized_input_field
  }
  NValue::Object(normalized_object)
}

///|
pub fn underlying_type_name(t : @graphql.GType) -> @graphql.TypeName {
  match t.base {
    Named(n) => n
    List(inner) => underlying_type_name(inner)
  }
}

///|
/// スキーマから入力型情報を引く
pub fn lookup_input_type(
  schema : Schema,
  t : @graphql.GType,
) -> InputType raise ValidationError {
  let base = underlying_type_name(t)
  let type_info = match schema.get_type(base) {
    Some(ti) => ti
    None => raise InternalTypeNotFound(type_name=base.as_str())
  }
  match type_info.as_input_type() {
    Some(it) => it
    None =>
      raise InternalNotInputType(
        type_name=base.as_str(),
        actual_type=type_info.kind(),
      )
  }
}
