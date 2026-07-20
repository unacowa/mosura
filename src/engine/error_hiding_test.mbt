// 内部エラーの秘匿 (#39): V3 準拠で本番は "internal error" のみを返し、
// DB エラー文やスキーマ情報などの内部詳細をクライアントへ露出しない。

///|
test "internal error: 本番モードは詳細を秘匿する" {
  // 生の DB エラーにはカラム名など内部情報が含まれ得る
  inspect(
    internal_error_json(
      false, "execution failed: column \"salary\" does not exist",
    ).stringify(),
    content=(
      #|{"errors":[{"message":"internal error"}]}
    ),
  )
}

///|
test "internal error: 開発モードは詳細を含める" {
  inspect(
    internal_error_json(true, "execution failed: connection refused").stringify(),
    content=(
      #|{"errors":[{"message":"internal error: execution failed: connection refused"}]}
    ),
  )
}
