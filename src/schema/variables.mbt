// lang-graphql/src/validation/variables.rs の移植 (Validate モードのみ)

///|
pub enum VariableValue {
  Provided(Json, @graphql.GType)
  VDefault(@graphql.ConstValue, @graphql.GType)
}

///|
pub struct Variable {
  definition : @graphql.VariableDefinition
  input_schema : InputType
  value : VariableValue?
}

///|
/// オペレーションの変数コンテキスト
pub(all) struct Variables {
  variables : Map[@graphql.Name, Variable]
}

///|
pub fn Variables::new(
  operation : @graphql.OperationDefinition,
  variable_values : Map[String, Json],
  schema : Schema,
) -> Variables raise ValidationError {
  let variables : Map[@graphql.Name, Variable] = Map([])
  match operation.variable_definitions {
    Some(variable_definitions) =>
      for variable_definition in variable_definitions.item {
        let definition = variable_definition.item
        let variable_name = definition.name.item
        let variable_type = definition.var_type.item
        let variable_base_type = underlying_type_name(variable_type)
        let type_info = match schema.get_type(variable_base_type) {
          Some(ti) => ti
          None => raise UnknownType(variable_base_type.as_str())
        }
        let input_schema = match type_info.as_input_type() {
          Some(it) => it
          None =>
            raise NotInputType(
              variable_name=variable_name.as_str(),
              type_name=variable_base_type.as_str(),
            )
        }
        let variable_nullable = variable_type.nullable
        let provided = variable_values.get(variable_name.as_str())
        let value : VariableValue? = match
          (provided, definition.default_value) {
          (None, Some(default_value)) =>
            Some(VDefault(default_value.item, variable_type))
          (None, None) => {
            if !variable_nullable {
              raise ExpectingValueForNonNullableVariable(
                variable_name=variable_name.as_str(),
                variable_type=gtype_display(variable_type),
              )
            }
            None
          }
          (Some(value), _) => {
            if !variable_nullable && value is Json::Null {
              raise NullValueForNonNullVariable(
                variable_name=variable_name.as_str(),
                variable_type=gtype_display(variable_type),
              )
            }
            Some(Provided(value, variable_type))
          }
        }
        if variables.contains(variable_name) {
          raise DuplicateVariableDeclarations(
            variable_name=variable_name.as_str(),
          )
        }
        variables[variable_name] = { definition, input_schema, value }
      }
    None => ()
  }
  { variables, }
}

///|
/// 変数参照を解決して正規化済み値を返す
pub fn Variables::get(
  self : Variables,
  ctx : NormalizeCtx,
  location_type : LocationType,
  variable_name : @graphql.Name,
) -> NValue raise ValidationError {
  let variable = match self.variables.get(variable_name) {
    Some(v) => v
    None => raise VariableNotDefined(variable_name=variable_name.as_str())
  }
  let variable_type = variable.definition.var_type.item

  // デフォルト値がどこかにある場合はベース型のみの互換性でよい
  let variable_spread_allowed = if location_type.default_value is Some(_) ||
    variable.definition.default_value is Some(_) {
    are_base_types_compatible(variable_type.base, location_type.ty.base)
  } else {
    are_types_compatible(variable_type, location_type.ty)
  }
  if variable_spread_allowed {
    // 変数値の正規化ではネストした変数参照は無いので variables を外したコンテキストで処理
    let inner_ctx : NormalizeCtx = {
      schema: ctx.schema,
      ns: ctx.ns,
      variables: None,
    }
    match variable.value {
      None =>
        match location_type.default_value {
          Some(default_value) =>
            normalize_input(
              inner_ctx,
              VConst(default_value),
              location_type,
              variable.input_schema,
            )
          None => SimpleValue(NNull)
        }
      Some(Provided(json, ty)) =>
        normalize_input(
          inner_ctx,
          VJson(json),
          { ty, default_value: None },
          variable.input_schema,
        )
      Some(VDefault(const_value, ty)) =>
        normalize_input(
          inner_ctx,
          VConst(const_value),
          { ty, default_value: None },
          variable.input_schema,
        )
    }
  } else {
    raise VariableSpreadNotAllowed(
      variable_name=variable_name.as_str(),
      variable_type=gtype_display(variable_type),
      location_type=gtype_display(location_type.ty),
    )
  }
}

///|
fn are_base_types_compatible(
  variable_type : @graphql.BaseType,
  location_type : @graphql.BaseType,
) -> Bool {
  match (variable_type, location_type) {
    (Named(v), Named(l)) => v == l
    (List(v), List(l)) => are_types_compatible(v, l)
    _ => false
  }
}

///|
fn are_types_compatible(
  variable_type : @graphql.GType,
  location_type : @graphql.GType,
) -> Bool {
  let nullability_ok = location_type.nullable || !variable_type.nullable
  are_base_types_compatible(variable_type.base, location_type.base) &&
  nullability_ok
}
