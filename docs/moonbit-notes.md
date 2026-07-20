# MoonBit / moon ハマりどころ集

このプロジェクトの開発中に実際に踏んだ問題と回避策。deny-warn (warning = エラー) 前提。
新しく踏んだものはここに追記すること。

## moon コマンド

- `moon test` / `moon run` は `moon.mod` の `preferred_target` で走る。
  **常に `--target native` を明示**する (依存に native 専用パッケージがある)
- `moon build --target native` は依存パッケージの C コードまでビルドし、
  postgres クライアントの TLS 部分が C コンパイラ警告で落ちることがある。
  検証には `moon check` / `moon test` を使う
- `moon fmt` はコードを積極的に再整形する。**スクリプトで連続置換する場合、
  fmt を挟むとアンカーがずれて置換が空振りする** — 置換後に grep で適用を確認する
- 依存追加は `moon.mod` の `import` にバージョン付きで記述 → `moon install`。
  `.mooncakes/<org>/<pkg>/pkg.generated.mbti` で公開 API を確認できる
- CI 注意: MoonBit 配布サーバは latest のみホスト (バージョン固定不可、issue #2)。
  レジストリ利用前に `moon update` が必要

## moon.pkg

- import 構文: `import { "path/to/pkg" @alias, ... }`。テスト専用は
  `import { ... } for "test"` ブロックに分ける (本体で未使用だと deny-warn で落ちるため)
- コアの `moonbitlang/core/*` も明示 import が必要 (`sorted_map` などは警告が出る)

## 言語・標準ライブラリ (deny-warn で落ちる非推奨 API)

| 非推奨 / 存在しない | 代替 |
|---|---|
| `try? expr` | `try expr catch { e => ... } noraise { ... }` (テストの異常系)。Result が本当に必要な時だけ `Ok/Err` を作る |
| `s.substring(start=n)` | `s[n:].to_owned()` |
| StringView の `.to_string()` | `.to_owned()` |
| `s.trim_end("=")` (位置引数) | `s.trim_end(chars="=")` |
| `.size()` (Map) | `.length()` |
| `derive(Show)` | `derive(Debug)`。ただし **Debug は文字列補間 `\{x}` に使えない** — 補間が必要なら手書きのシリアライザを書く |
| `String::charcode_at` | 存在しない。`s.to_array()` で `Array[Char]` にして `.to_int()` |

## 言語セマンティクスの罠

- **String の既定 `Compare` は長さ優先** (length-first)。Rust の BTreeMap と順序を
  合わせる必要がある箇所は辞書順比較を自前実装する (`src/graphql` の `lex_compare`)
- `String::replace` は**最初の 1 箇所のみ**置換。全置換は `replace_all(old=, new=)`
- 予約語: `alias` / `extend` / `member` はフィールド名等に使えない (`alias_` などにする)
- `Json::Number(Double, repr~ : String?)` — repr を保持するので数値比較は
  repr 無視の構造比較を書く (execute ハーネスの `json_equal`)
- 抽象 `Error` はコンストラクタでマッチできない。typed catch (`catch { @pkg.SubError(...) => }`)
  か Result を返すヘルパで受ける
- `Option` は補間 `\{x}` 不可 (Show なし) — match で取り出す
- struct 更新構文 `{ ..base, field: v }` は使える
- 配列は参照。`[set_]` のようにラップしても元の配列への push は共有される (意図的に利用可)

## async / テスト

- `async test "..." { }` が書ける。E2E は `@async.with_task_group` 内で
  `NativeExecutor::connect` → `group.spawn_bg(() => connection.run())` のパターン
- **テストは並列実行される**。実 DB を触るテストはテーブル名にテスト毎のサフィックスを付ける
- `inspect(x, content=...)` はスナップショットテスト。`moon test --update` で更新できるが、
  意図しない更新を避けるため原則手で書く

## moonbit-community/postgres (v0.0.6)

- json/jsonb カラムは `let j : Json = row.get(0)` で受ける (`get_text` はバイナリ形式で失敗する)
- 文字列のセッション変数を int 等のパラメータに使う場合は
  `query_typed(sql, types, params)` で**全パラメータを `@client.Type::text()` 宣言**し、
  SQL 側の cast に変換させる (クライアント側の型チェックを回避)
- `batch_execute` は COPY 形式を実行できない。pg_dump のシードは INSERT に変換する
  (`scripts/convert_execute_seed.py`。`OWNER TO` 等のロール依存文も除去)
- TLS 周りの C コードが `moon build` で警告落ちすることがある (moon check は通る)

## gmlewis/sha256, gmlewis/base64 (JWT で使用)

- `@sha256.gen_hmac(body, key)` は **base64url (パディング付き)** の文字列を返す。
  JWT 署名と比較する時は両辺の `=` を除去してから比較
- `@base64.url_decode2str(s, no_padding=true)` / `str2bytes` (UTF-8 変換) が使える

## シェル操作の注意 (このリポジトリでの作業全般)

- `pkill -f moon` は自分のシェルまで殺すことがある (exit 144)。PID を個別に kill する
- Python heredoc に `\N` を含むテキストを埋め込むと unicode escape エラー。
  クォート付き heredoc (`<<'EOF'`) でファイルに書いてから実行する
