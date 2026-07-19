// Rust の {:#?} (pretty Debug) と同一の文字列を生成するプリンタ。
// フィクスチャ (移植元のゴールデンファイル) とバイト一致させるために使う。

///|
priv struct DebugWriter {
  sb : StringBuilder
}

///|
fn DebugWriter::new() -> DebugWriter {
  { sb: StringBuilder::new() }
}

///|
fn DebugWriter::pad(self : DebugWriter, indent : Int) -> Unit {
  for _ in 0..<(indent * 4) {
    self.sb.write_char(' ')
  }
}

///|
fn DebugWriter::write(self : DebugWriter, s : String) -> Unit {
  self.sb.write_string(s)
}

///|
/// タプル型バリアント: `Name(\n    <inner>,\n)` (Rust では要素ごとに 1 行)
fn DebugWriter::tuple1(
  self : DebugWriter,
  indent : Int,
  name : String,
  inner : (DebugWriter, Int) -> Unit,
) -> Unit {
  self.write(name)
  self.write("(\n")
  self.pad(indent + 1)
  inner(self, indent + 1)
  self.write(",\n")
  self.pad(indent)
  self.write(")")
}

///|
/// 構造体: `Name {\n    key: <v>,\n}`
fn DebugWriter::strukt(
  self : DebugWriter,
  indent : Int,
  name : String,
  fields : Array[(String, (DebugWriter, Int) -> Unit)],
) -> Unit {
  self.write(name)
  self.write(" {\n")
  for field in fields {
    let (key, render) = field
    self.pad(indent + 1)
    self.write(key)
    self.write(": ")
    render(self, indent + 1)
    self.write(",\n")
  }
  self.pad(indent)
  self.write("}")
}

///|
/// リスト: `[]` または `[\n    <item>,\n]`
fn[T] DebugWriter::list(
  self : DebugWriter,
  indent : Int,
  items : Array[T],
  render : (DebugWriter, Int, T) -> Unit,
) -> Unit {
  if items.is_empty() {
    self.write("[]")
  } else {
    self.write("[\n")
    for item in items {
      self.pad(indent + 1)
      render(self, indent + 1, item)
      self.write(",\n")
    }
    self.pad(indent)
    self.write("]")
  }
}

///|
fn[T] DebugWriter::option(
  self : DebugWriter,
  indent : Int,
  value : T?,
  render : (DebugWriter, Int, T) -> Unit,
) -> Unit {
  match value {
    None => self.write("None")
    Some(v) => self.tuple1(indent, "Some", (w, ind) => render(w, ind, v))
  }
}

///|
/// Rust の str::escape_debug 相当
fn rust_escape_string(s : String) -> String {
  let sb = StringBuilder::new()
  for c in s {
    rust_escape_char_into(sb, c, '"')
  }
  sb.to_string()
}

///|
fn rust_escape_char_into(sb : StringBuilder, c : Char, quote : Char) -> Unit {
  if c == '\n' {
    sb.write_string("\\n")
  } else if c == '\r' {
    sb.write_string("\\r")
  } else if c == '\t' {
    sb.write_string("\\t")
  } else if c == '\\' {
    sb.write_string("\\\\")
  } else if c == quote {
    sb.write_char('\\')
    sb.write_char(quote)
  } else {
    let code = c.to_int()
    if code < 0x20 || code == 0x7F {
      sb.write_string("\\u{")
      sb.write_string(to_hex_lower(code))
      sb.write_string("}")
    } else {
      sb.write_char(c)
    }
  }
}

///|
fn to_hex_lower(n : Int) -> String {
  let digits : Array[Char] = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
  ]
  if n == 0 {
    return "0"
  }
  let sb = StringBuilder::new()
  let parts : Array[Char] = []
  let mut v = n
  while v > 0 {
    parts.push(digits[v % 16])
    v = v / 16
  }
  parts.rev_each(c => sb.write_char(c))
  sb.to_string()
}

///|
fn debug_string(w : DebugWriter, s : String) -> Unit {
  w.write("\"")
  w.write(rust_escape_string(s))
  w.write("\"")
}

///|
fn debug_char(w : DebugWriter, c : Char) -> Unit {
  let sb = StringBuilder::new()
  sb.write_char('\'')
  rust_escape_char_into(sb, c, '\'')
  sb.write_char('\'')
  w.write(sb.to_string())
}

///|
/// Rust の f64 Debug 表示 (整数値は ".0" が付く)
pub fn rust_f64_display(f : Double) -> String {
  let s = f.to_string()
  if s.contains(".") ||
    s.contains("e") ||
    s.contains("E") ||
    s.contains("inf") ||
    s.contains("nan") {
    s
  } else {
    s + ".0"
  }
}

// ---------------------------------------------------------------------------
// AST ノードのレンダリング
// ---------------------------------------------------------------------------

///|
fn debug_name(w : DebugWriter, indent : Int, name : Name) -> Unit {
  w.tuple1(indent, "Name", (w, _ind) => debug_string(w, name.as_str()))
}

///|
fn debug_type_name(w : DebugWriter, indent : Int, tn : TypeName) -> Unit {
  w.tuple1(indent, "TypeName", (w, ind) => debug_name(w, ind, tn.0))
}

///|
fn debug_source_position(
  w : DebugWriter,
  indent : Int,
  p : SourcePosition,
) -> Unit {
  w.strukt(indent, "SourcePosition", [
    ("line", (w, _i) => w.write(p.line.to_string())),
    ("col", (w, _i) => w.write(p.col.to_string())),
  ])
}

///|
fn[T] debug_spanning(
  w : DebugWriter,
  indent : Int,
  s : Spanning[T],
  render : (DebugWriter, Int, T) -> Unit,
) -> Unit {
  w.strukt(indent, "Spanning", [
    ("item", (w, i) => render(w, i, s.item)),
    ("start", (w, i) => debug_source_position(w, i, s.start)),
    ("end", (w, i) => debug_source_position(w, i, s.end)),
  ])
}

///|
fn[T] debug_positioned(
  w : DebugWriter,
  indent : Int,
  p : Positioned[T],
  render : (DebugWriter, Int, T) -> Unit,
) -> Unit {
  w.strukt(indent, "Positioned", [
    ("item", (w, i) => render(w, i, p.item)),
    ("position", (w, i) => debug_source_position(w, i, p.position)),
  ])
}

///|
fn debug_simple_value(w : DebugWriter, indent : Int, v : SimpleValue) -> Unit {
  match v {
    Null => w.write("Null")
    Id(s) => w.tuple1(indent, "Id", (w, _i) => debug_string(w, s))
    Integer(i) => w.tuple1(indent, "Integer", (w, _i) => w.write(i.to_string()))
    Float(f) =>
      w.tuple1(indent, "Float", (w, _i) => w.write(rust_f64_display(f)))
    SVString(s) => w.tuple1(indent, "String", (w, _i) => debug_string(w, s))
    Boolean(b) => w.tuple1(indent, "Boolean", (w, _i) => w.write(b.to_string()))
    SVEnum(n) => w.tuple1(indent, "Enum", (w, i) => debug_name(w, i, n))
  }
}

///|
fn[V] debug_key_value(
  w : DebugWriter,
  indent : Int,
  kv : KeyValue[V],
  render : (DebugWriter, Int, V) -> Unit,
) -> Unit {
  w.strukt(indent, "KeyValue", [
    ("key", (w, i) => debug_spanning(w, i, kv.key, debug_name)),
    ("value", (w, i) => debug_spanning(w, i, kv.value, render)),
  ])
}

///|
fn debug_const_value(w : DebugWriter, indent : Int, v : ConstValue) -> Unit {
  match v {
    SimpleValue(sv) =>
      w.tuple1(indent, "SimpleValue", (w, i) => debug_simple_value(w, i, sv))
    List(items) =>
      w.tuple1(indent, "List", (w, i) => {
        w.list(i, items, (w, i, item) => {
          debug_spanning(w, i, item, debug_const_value)
        })
      })
    Object(items) =>
      w.tuple1(indent, "Object", (w, i) => {
        w.list(i, items, (w, i, item) => {
          debug_spanning(w, i, item, (w, i, kv) => {
            debug_key_value(w, i, kv, debug_const_value)
          })
        })
      })
  }
}

///|
fn debug_value(w : DebugWriter, indent : Int, v : Value) -> Unit {
  match v {
    Variable(n) => w.tuple1(indent, "Variable", (w, i) => debug_name(w, i, n))
    SimpleValue(sv) =>
      w.tuple1(indent, "SimpleValue", (w, i) => debug_simple_value(w, i, sv))
    List(items) =>
      w.tuple1(indent, "List", (w, i) => {
        w.list(i, items, (w, i, item) => debug_spanning(w, i, item, debug_value))
      })
    Object(items) =>
      w.tuple1(indent, "Object", (w, i) => {
        w.list(i, items, (w, i, item) => {
          debug_spanning(w, i, item, (w, i, kv) => {
            debug_key_value(w, i, kv, debug_value)
          })
        })
      })
  }
}

///|
fn debug_base_type(w : DebugWriter, indent : Int, b : BaseType) -> Unit {
  match b {
    Named(tn) => w.tuple1(indent, "Named", (w, i) => debug_type_name(w, i, tn))
    List(tc) => w.tuple1(indent, "List", (w, i) => debug_gtype(w, i, tc))
  }
}

///|
fn debug_gtype(w : DebugWriter, indent : Int, t : GType) -> Unit {
  w.strukt(indent, "TypeContainer", [
    ("base", (w, i) => debug_base_type(w, i, t.base)),
    ("nullable", (w, _i) => w.write(t.nullable.to_string())),
  ])
}

///|
fn debug_operation_type(w : DebugWriter, ty : OperationType) -> Unit {
  match ty {
    Query => w.write("Query")
    Mutation => w.write("Mutation")
    Subscription => w.write("Subscription")
  }
}

///|
fn debug_directive(w : DebugWriter, indent : Int, d : Directive) -> Unit {
  w.strukt(indent, "Directive", [
    ("name", (w, i) => debug_spanning(w, i, d.name, debug_name)),
    (
      "arguments",
      (w, i) => {
        w.option(i, d.arguments, (w, i, args) => {
          debug_spanning(w, i, args, (w, i, items) => {
            w.list(i, items, debug_argument)
          })
        })
      },
    ),
  ])
}

///|
fn debug_argument(w : DebugWriter, indent : Int, a : Argument) -> Unit {
  debug_spanning(w, indent, a, (w, i, kv) => {
    debug_key_value(w, i, kv, debug_value)
  })
}

///|
fn debug_directives(
  w : DebugWriter,
  indent : Int,
  ds : Array[Spanning[Directive]],
) -> Unit {
  w.list(indent, ds, (w, i, d) => debug_spanning(w, i, d, debug_directive))
}

///|
fn debug_variable_definition(
  w : DebugWriter,
  indent : Int,
  vd : VariableDefinition,
) -> Unit {
  w.strukt(indent, "VariableDefinition", [
    ("name", (w, i) => debug_spanning(w, i, vd.name, debug_name)),
    ("var_type", (w, i) => debug_spanning(w, i, vd.var_type, debug_gtype)),
    (
      "default_value",
      (w, i) => {
        w.option(i, vd.default_value, (w, i, dv) => {
          debug_spanning(w, i, dv, debug_const_value)
        })
      },
    ),
  ])
}

///|
fn debug_selection_set(
  w : DebugWriter,
  indent : Int,
  ss : SelectionSet,
) -> Unit {
  w.strukt(indent, "SelectionSet", [
    (
      "items",
      (w, i) => {
        w.list(i, ss.items, (w, i, s) => {
          debug_spanning(w, i, s, debug_selection)
        })
      },
    ),
  ])
}

///|
fn debug_type_condition(
  w : DebugWriter,
  indent : Int,
  tc : TypeCondition,
) -> Unit {
  w.strukt(indent, "TypeCondition", [
    ("on", (w, i) => debug_spanning(w, i, tc.on, debug_type_name)),
  ])
}

///|
fn debug_selection(w : DebugWriter, indent : Int, s : Selection) -> Unit {
  match s {
    Field(f) =>
      w.tuple1(indent, "Field", (w, i) => {
        w.strukt(i, "Field", [
          (
            "alias",
            (w, i) => {
              w.option(i, f.field_alias, (w, i, a) => {
                debug_spanning(w, i, a, (w, i, al) => {
                  w.tuple1(i, "Alias", (w, i) => debug_name(w, i, al.0))
                })
              })
            },
          ),
          ("name", (w, i) => debug_spanning(w, i, f.name, debug_name)),
          (
            "arguments",
            (w, i) => {
              w.option(i, f.arguments, (w, i, args) => {
                debug_spanning(w, i, args, (w, i, items) => {
                  w.list(i, items, debug_argument)
                })
              })
            },
          ),
          ("directives", (w, i) => debug_directives(w, i, f.directives)),
          (
            "selection_set",
            (w, i) => {
              w.option(i, f.selection_set, (w, i, ss) => {
                debug_spanning(w, i, ss, debug_selection_set)
              })
            },
          ),
        ])
      })
    FragmentSpread(fs) =>
      w.tuple1(indent, "FragmentSpread", (w, i) => {
        w.strukt(i, "FragmentSpread", [
          (
            "fragment_name",
            (w, i) => debug_spanning(w, i, fs.fragment_name, debug_name),
          ),
          ("directives", (w, i) => debug_directives(w, i, fs.directives)),
        ])
      })
    InlineFragment(inf) =>
      w.tuple1(indent, "InlineFragment", (w, i) => {
        w.strukt(i, "InlineFragment", [
          (
            "type_condition",
            (w, i) => {
              w.option(i, inf.type_condition, (w, i, tc) => {
                debug_spanning(w, i, tc, debug_type_condition)
              })
            },
          ),
          ("directives", (w, i) => debug_directives(w, i, inf.directives)),
          (
            "selection_set",
            (w, i) => {
              debug_spanning(w, i, inf.selection_set, debug_selection_set)
            },
          ),
        ])
      })
  }
}

///|
fn debug_operation_definition(
  w : DebugWriter,
  indent : Int,
  op : OperationDefinition,
) -> Unit {
  w.strukt(indent, "OperationDefinition", [
    ("ty", (w, _i) => debug_operation_type(w, op.ty)),
    (
      "name",
      (w, i) => {
        w.option(i, op.name, (w, i, n) => debug_spanning(w, i, n, debug_name))
      },
    ),
    (
      "variable_definitions",
      (w, i) => {
        w.option(i, op.variable_definitions, (w, i, vds) => {
          debug_spanning(w, i, vds, (w, i, items) => {
            w.list(i, items, (w, i, vd) => {
              debug_spanning(w, i, vd, debug_variable_definition)
            })
          })
        })
      },
    ),
    ("directives", (w, i) => debug_directives(w, i, op.directives)),
    (
      "selection_set",
      (w, i) => debug_spanning(w, i, op.selection_set, debug_selection_set),
    ),
  ])
}

///|
fn debug_fragment_definition(
  w : DebugWriter,
  indent : Int,
  fd : FragmentDefinition,
) -> Unit {
  w.strukt(indent, "FragmentDefinition", [
    ("name", (w, i) => debug_spanning(w, i, fd.name, debug_name)),
    (
      "type_condition",
      (w, i) => debug_spanning(w, i, fd.type_condition, debug_type_condition),
    ),
    ("directives", (w, i) => debug_directives(w, i, fd.directives)),
    (
      "selection_set",
      (w, i) => debug_spanning(w, i, fd.selection_set, debug_selection_set),
    ),
  ])
}

///|
fn debug_executable_definition(
  w : DebugWriter,
  indent : Int,
  d : ExecutableDefinition,
) -> Unit {
  match d {
    Operation(op) =>
      w.tuple1(indent, "Operation", (w, i) => {
        debug_operation_definition(w, i, op)
      })
    Fragment(fd) =>
      w.tuple1(indent, "Fragment", (w, i) => debug_fragment_definition(w, i, fd))
  }
}

///|
pub fn debug_executable_document(doc : ExecutableDocument) -> String {
  let w = DebugWriter::new()
  w.strukt(0, "ExecutableDocument", [
    (
      "items",
      (w, i) => {
        w.list(i, doc.items, (w, i, d) => {
          debug_spanning(w, i, d, debug_executable_definition)
        })
      },
    ),
  ])
  w.sb.to_string()
}

// ---------------------------------------------------------------------------
// エラーのレンダリング
// ---------------------------------------------------------------------------

///|
fn debug_keyword(w : DebugWriter, k : Keyword) -> Unit {
  w.write(
    match k {
      True => "True"
      False => "False"
      Null => "Null"
      Fragment => "Fragment"
      On => "On"
      Query => "Query"
      Mutation => "Mutation"
      Subscription => "Subscription"
      Type => "Type"
      Input => "Input"
      Enum => "Enum"
      Scalar => "Scalar"
      Implements => "Implements"
      Interface => "Interface"
      Union => "Union"
      Schema => "Schema"
    },
  )
}

///|
fn debug_punctuation(w : DebugWriter, p : Punctuation) -> Unit {
  w.write(
    match p {
      Bang => "Bang"
      Dollar => "Dollar"
      Amp => "Amp"
      ParenL => "ParenL"
      ParenR => "ParenR"
      Spread => "Spread"
      Colon => "Colon"
      Equals => "Equals"
      At => "At"
      BracketL => "BracketL"
      BracketR => "BracketR"
      BraceL => "BraceL"
      Pipe => "Pipe"
      BraceR => "BraceR"
    },
  )
}

///|
fn debug_expected_token(
  w : DebugWriter,
  indent : Int,
  e : ExpectedToken,
) -> Unit {
  match e {
    Keyword(k) => w.tuple1(indent, "Keyword", (w, _i) => debug_keyword(w, k))
    Punctuation(p) =>
      w.tuple1(indent, "Punctuation", (w, _i) => debug_punctuation(w, p))
    Name => w.write("Name")
    Number => w.write("Number")
    TString => w.write("String")
  }
}

///|
fn debug_byte_option(w : DebugWriter, indent : Int, b : Byte?) -> Unit {
  w.option(indent, b, (w, _i, byte) => w.write(byte.to_int().to_string()))
}

///|
fn debug_string_error(w : DebugWriter, indent : Int, e : StringError) -> Unit {
  match e {
    StartingSequenceNotFound(b) =>
      w.tuple1(indent, "StartingSequenceNotFound", (w, i) => {
        debug_byte_option(w, i, b)
      })
    Unterminated => w.write("Unterminated")
    UnknownCharacterInString(c) =>
      w.tuple1(indent, "UnknownCharacterInString", (w, _i) => debug_char(w, c))
    UnknownEscapeSequence(s) =>
      w.tuple1(indent, "UnknownEscapeSequence", (w, _i) => debug_string(w, s))
    InvalidUnicodeEscapeSequence(s) =>
      w.tuple1(indent, "InvalidUnicodeEscapeSequence", (w, _i) => {
        debug_string(w, s)
      })
  }
}

///|
fn debug_number_error(w : DebugWriter, indent : Int, e : NumberError) -> Unit {
  match e {
    DigitExpected(found) =>
      w.strukt(indent, "DigitExpected", [
        ("found", (w, i) => debug_byte_option(w, i, found)),
      ])
    LexicalError(msg) =>
      w.strukt(indent, "LexicalError", [("error", (w, _i) => w.write(msg))])
    NameStart(b) =>
      w.tuple1(indent, "NameStart", (w, _i) => w.write(b.to_int().to_string()))
  }
}

///|
fn debug_lexer_error(w : DebugWriter, indent : Int, e : LexerError) -> Unit {
  match e {
    UnexpectedCharacter(c) =>
      w.tuple1(indent, "UnexpectedCharacter", (w, _i) => debug_char(w, c))
    UnexpectedEndOfFile => w.write("UnexpectedEndOfFile")
    InvalidString(se) =>
      w.tuple1(indent, "InvalidString", (w, i) => debug_string_error(w, i, se))
    InvalidNumber(ne) =>
      w.tuple1(indent, "InvalidNumber", (w, i) => debug_number_error(w, i, ne))
    InvalidGraphQlName(s) =>
      w.tuple1(indent, "InvalidGraphQlName", (w, _i) => debug_string(w, s))
  }
}

///|
fn debug_token(w : DebugWriter, indent : Int, t : Token) -> Unit {
  match t {
    Punctuation(p) =>
      w.tuple1(indent, "Punctuation", (w, _i) => debug_punctuation(w, p))
    Name(n) => w.tuple1(indent, "Name", (w, i) => debug_name(w, i, n))
    Number(Int64(i)) =>
      w.tuple1(indent, "Number", (w, i2) => {
        w.tuple1(i2, "Int64", (w, _i) => w.write(i.to_string()))
      })
    Number(Float64(f)) =>
      w.tuple1(indent, "Number", (w, i2) => {
        w.tuple1(i2, "Float64", (w, _i) => w.write(rust_f64_display(f)))
      })
    TString(s) => w.tuple1(indent, "String", (w, _i) => debug_string(w, s))
  }
}

///|
fn debug_token_found(w : DebugWriter, indent : Int, tf : TokenFound) -> Unit {
  match tf {
    EndOfFile => w.write("EndOfFile")
    LexerError(e) =>
      w.tuple1(indent, "LexerError", (w, i) => debug_lexer_error(w, i, e))
    Token(t) => w.tuple1(indent, "Token", (w, i) => debug_token(w, i, t))
  }
}

///|
fn debug_parse_error(w : DebugWriter, indent : Int, e : ParseError) -> Unit {
  match e {
    TokenError(expected_tokens~, found~) =>
      w.strukt(indent, "TokenError", [
        (
          "expected_tokens",
          (w, i) => w.list(i, expected_tokens, debug_expected_token),
        ),
        ("found", (w, i) => debug_token_found(w, i, found)),
      ])
    OtherError(msg) =>
      w.tuple1(indent, "OtherError", (w, _i) => debug_string(w, msg))
  }
}

///|
/// パース結果を Rust の `{:#?}` (Result<_, Positioned<Error>>) と同一形式で表示する
pub fn debug_parse_result(
  result : Result[ExecutableDocument, Positioned[ParseError]],
) -> String {
  let w = DebugWriter::new()
  match result {
    Ok(doc) =>
      w.tuple1(0, "Ok", (w, i) => {
        // 内側のドキュメントはインデント i から始まる
        let inner = debug_executable_document_at(doc, i)
        w.write(inner)
      })
    Err(err) =>
      w.tuple1(0, "Err", (w, i) => {
        debug_positioned(w, i, err, debug_parse_error)
      })
  }
  w.sb.to_string()
}

///|
fn debug_executable_document_at(
  doc : ExecutableDocument,
  indent : Int,
) -> String {
  let w = DebugWriter::new()
  w.strukt(indent, "ExecutableDocument", [
    (
      "items",
      (w, i) => {
        w.list(i, doc.items, (w, i, d) => {
          debug_spanning(w, i, d, debug_executable_definition)
        })
      },
    ),
  ])
  w.sb.to_string()
}
