///|
/// ソース位置 (1-origin)。lexer/parser のエラー報告と AST ノードに付与する。
pub struct Position {
  line : Int
  column : Int
} derive(Eq, Debug)

///|
pub fn Position::start() -> Position {
  { line: 1, column: 1 }
}
