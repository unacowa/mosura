// lang-graphql/src/ast/spanning.rs の移植

///|
/// ソース中の行・列位置 (1-origin)
pub(all) struct SourcePosition {
  line : Int
  col : Int
} derive(Eq, Compare, Hash)

///|
pub fn SourcePosition::new(line : Int, col : Int) -> SourcePosition {
  { line, col }
}

///|
/// 開始位置つきの値
pub(all) struct Positioned[T] {
  item : T
  position : SourcePosition
} derive(Eq)

///|
pub fn[T] Positioned::new(position : SourcePosition, item : T) -> Positioned[T] {
  { item, position }
}

///|
pub fn[T, O] Positioned::map(
  self : Positioned[T],
  f : (T) -> O,
) -> Positioned[O] {
  { item: f(self.item), position: self.position }
}

///|
/// 開始・終了位置つきの値
pub(all) struct Spanning[T] {
  item : T
  start : SourcePosition
  end : SourcePosition
} derive(Eq)

///|
pub fn[T] Spanning::single_width(pos : SourcePosition, item : T) -> Spanning[T] {
  { item, start: pos, end: pos }
}

///|
pub fn[T] Spanning::start_end(
  start : SourcePosition,
  end : SourcePosition,
  item : T,
) -> Spanning[T] {
  { item, start, end }
}

///|
pub fn[T, O] Spanning::map(self : Spanning[T], f : (T) -> O) -> Spanning[O] {
  { item: f(self.item), start: self.start, end: self.end }
}
