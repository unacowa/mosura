# M0–M7 詳細実装計画

作成日: 2026-07-20
前提: [architecture.md](architecture.md)（設計）、[feasibility-check.md](feasibility-check.md)（依存検証）
開発方針: **TDD**（§1）。移植元のテスト資産を先に取り込み、フィクスチャ合格率を進捗指標とする。

## 0. 事前スパイクで解消済みの懸念

M0 着手前にすべて実機検証した（検証コードは scratchpad `testlab/`）。

| # | 懸念 | 結果 |
|---|------|------|
| 1 | async/IO の実行モデル | `async fn main` + `@async.with_task_group` で動作確認。`with_event_loop` は現行 async(0.20.2) に存在しない（古い記事に注意） |
| 2 | HTTP サーバの手段 | `moonbitlang/async/http` に `Server::run_forever(handler)` が内蔵。tls / websocket / js_async パッケージもあり。自作不要 |
| 3 | YAML の機能網羅性 | アンカー/エイリアス・ブロックスカラー(`\|`)・int/float/bool/null・マルチドキュメント・`ToJson` 変換をすべて確認。**制限: マージキー `<<:` は展開されずリテラルキー `"<<"` として残る** → metadata loader で Json 後処理として展開する（実装は数十行）。`YamlError` は `Show` 未実装 → `mark`（行/列）から自前整形 |
| 4 | 動的クエリ結果の行デコード | ndc-postgres 方式（レスポンス全体を SQL 側で `json_build_object`/`json_agg` して **text 1 カラム**で受ける）を実 PG16 で確認。行→GraphQL 値の型マッピング問題がクライアント側からほぼ消える |
| 5 | moon のマルチパッケージ構成 | `moon.pkg` の `import "username/mod/pkg" @alias` で内部パッケージ共有を確認。`inspect(x, content=...)` によるスナップショットテストも動作（ゴールデンテスト基盤に使える） |
| 6 | SCRAM / crypto | postgres クライアント内蔵のため自前実装不要（feasibility-check 済み） |
| 7 | テスト資産 | **V3 のテストフィクスチャが流用可能**。`lang-graphql/tests/{query,schema}_testdata`（.graphql 入力 + 期待 AST/エラーの .txt、正常系/異常系数百ケース）と `engine/tests/execute`（メタデータ + クエリ + 期待レスポンス JSON）。Apache 2.0 なので NOTICE に帰属表記の上で取り込む |

### 運用上の注意（スパイクで判明）

- `moon test` / `moon run` は `moon.mod` の `preferred_target`（デフォルト wasm-gc）で走る。
  **native 依存パッケージがあるため CI・手元とも `--target native` を明示**（または preferred_target を native に変更し、ターゲット非依存性は CI の js/wasm-gc チェックで担保）
- 依存はすべてバージョン固定。moon toolchain 自体も CI でバージョン固定（`moon version` チェック）

## 1. テスト戦略：Hasura のテスト資産を仕様とする TDD

**この移植の最も重要な合理性は、移植元のテストケースが揃っていることにある。**
したがって開発は全マイルストーンで TDD とする：実装より先にフィクスチャを取り込んで
レッドの状態を作り、グリーンにすることで進める。進捗の一次指標はコード量ではなく
**フィクスチャ合格率**（passed / in-scope）。

### 取り込むテスト資産（インベントリ、2026-07-20 時点の V3 で確認）

| 資産 | 規模 | 形式 | 検証対象 | 使う M |
|------|------|------|---------|--------|
| `lang-graphql/tests/{testdata,query_testdata,schema_testdata}` | .graphql 104 + 期待値 .txt 46（正常系 + エラー系） | 入力 .graphql → 期待 AST / 期待エラーのゴールデン | lexer / parser / validation | M1 |
| `metadata-resolve/tests/{passing,failing}` | 289 ケース（metadata.json + insta .snap） | メタデータ → 解決結果 / エラーのスナップショット | metadata resolve | M2 |
| `engine/tests/execute` | 229 ケース（metadata.json + request.gql + session_variables.json + expected.json、introspection 期待値付き） | GraphQL リクエスト → 最終レスポンスの E2E | エンジン全体 + 権限 | M2(introspection) / M4 / M5 / M6 |
| ndc-postgres `query-engine/translation/tests` | 121 ケース（QueryRequest JSON + 生成 SQL の insta スナップショット） | NDC QueryRequest → SQL | sqlgen | M3 |

このほか、移植元のインライン Rust unit test（`#[test]`）はデータとして取り込めないため、
対応するコードの移植と同時に手で移植する。

### 取り込みパイプライン（M0 で構築）

- `scripts/import-fixtures.sh`: `hasura/graphql-engine`（/v3）と `hasura/ndc-postgres` を
  **コミット固定**で shallow clone し、上記資産を `fixtures/` に正規化コピーする。
  insta 形式の .snap は `inspect(content=...)` で照合できる素の期待値ファイルに変換する
- ライセンス: 双方 Apache 2.0。ただし `lang-graphql/tests` には MIT 由来のテストデータが
  含まれる（LICENSE-MIT 同梱）ため、NOTICE に両方の帰属を記載する
- fixtures は git 管理に含める（取り込みスクリプトは再現手段であり、ビルドは fixtures だけで完結させる）

### スコープタグ：全部取り込み、選んで走らせる

**フィクスチャは選別せず全部取り込む。** その上で各ケースを `fixtures/cases.toml`（1 ケース 1 エントリ）で
タグ付けして管理する：

- `in-scope` — 対象。CI で必ず実行され、グリーンが維持される
- `pending` — 対象だが未実装のマイルストーンに属する（M の進行とともに in-scope へ移す）
- `out-of-scope(reason)` — MVP 対象外（例: aggregates, commands, apollo_federation, jsonapi,
  remote relationships, subscriptions）。**削除はしない**。スコープ判断が diff として可視化され、
  将来の拡張時にそのまま解凍できる

CI は毎ビルドで `passed / in-scope / pending / out-of-scope` の集計を出力する。

### engine E2E フィクスチャの実行系

V3 の `engine/tests/execute` は custom-connector（インメモリのテスト用コネクタ、8.7k LOC）を
前提にしている。custom-connector 自体は移植せず、**そのデータセット（actors / movies 等）を
PostgreSQL のシード SQL に変換し、fixtures の metadata を PG の DataConnectorLink に
書き換えるコンバータ**を M4 で作る。postgres-first の構成では、この方が実運用と同じ経路
（sqlgen + exec/native）でエンジン仕様を検証できる。custom-connector 固有機能に依存する
ケース（functions / procedures / ネスト集合型など）は out-of-scope タグで明示する。

## 2. 残存リスクと対応

| リスク | 対応 |
|--------|------|
| `moonbit-community/postgres` v0.0.6 の API 変更 | バージョン固定 + `SqlExecutor` trait で完全隔離（触るのは `exec/native` のみ） |
| MoonBit 0.x の破壊的変更 | toolchain 固定。`moon upgrade` は明示的なタスクとして実施 |
| JWT RS256（M5) | HS256 は `gen_hmac`（gmlewis/sha256）で実装可能。RS256 は M5 時点で `mjwt` 等を評価、なければ HS256 のみで出す |
| Mosura のライセンス | **Apache 2.0**（`moon new` の既定値のまま。V3 / ndc-postgres からの移植・フィクスチャ取り込みと整合し、NOTICE で帰属） |

## 3. 移植規模の見積り（Rust LOC ベース）

| 移植元 | LOC | Mosura での規模感 |
|--------|-----|------------------|
| lang-graphql: lexer 1.2k / parser 1.6k / ast 0.9k / normalized_ast 0.4k / schema 1.2k / validation 3.0k / introspection 0.7k | 約 9.0k（sdl/http 除外） | ほぼ全部移植。M1 の本体 |
| open-dds + metadata-resolve のサブセット | 元 37k → 使う kind に限定 | 型定義 + 解決/検証で 3〜5k 相当 |
| graphql/schema + ir + frontend | 約 14k | スキーマ生成 + IR。M2/M3 の本体 |
| ndc-postgres: translation 6.9k / sql 2.9k | 約 9.8k → クエリ先行サブセットで 5〜6k 相当 | sqlgen。M3 の本体 |

合計でおよそ 25k〜30k 行規模の MoonBit コードになる見込み。M1〜M3 が実装の山。

## 4. MVP スコープ定義

### GraphQL 機能

- **対応**: query（selection set / 引数 / variables / fragment / inline fragment / alias / `@skip` `@include`）、introspection（`__schema` `__type` `__typename`）、mutation（M6）
- **スコープ外**: subscription、Apollo Federation、`@defer`/`@stream`、SDL 出力

### メタデータ kind セット（Mosura v1）

| kind | 内容 | マイルストーン |
|------|------|---------------|
| `DataConnectorLink` | 接続先定義（`urlFromEnv` 等） | M2 |
| `ScalarType` / `ObjectType` | 型とフィールド（DB カラムへのマッピング含む） | M2 |
| `Model` | コレクション公開。`filterableFields` / `orderableFields` | M2 |
| `Relationship` | object / array リレーション | M2 |
| `ModelPermissions` | ロール別の行フィルタ（セッション変数参照） | M5 |
| `TypePermissions` | ロール別の出力カラム制限 | M5 |
| `AuthConfig` | admin secret / JWT 設定 | M5 |
| （mutation 関連） | Model からの自動 CRUD 生成設定 | M6 |

**設計判断**: mutation は V3 の Command 機構ではなく、**Model から `insert_<model>` / `update_<model>` / `delete_<model>` を自動生成する Hasura V2 風のアプローチ**を採る（V3 の Command は connector の procedure 前提で in-process 構成では過剰。将来必要になれば追加）。

### SQL 生成（sqlgen）

- SELECT: フィールド選択、where（`_eq _neq _gt _gte _lt _lte _in _like _is_null` + `_and _or _not`）、order_by（複数キー・nulls first/last）、limit/offset
- リレーション: LATERAL JOIN + `json_agg`（array）/ `row_to_json`（object）で単一 SQL に畳み込み
- レスポンスは SQL 側で JSON 組み立て → text 1 カラム受け（スパイク検証済みパターン）
- すべてパラメタライズ（`$n`）。セッション変数もパラメータとして渡す
- M6: INSERT / UPDATE / DELETE + RETURNING（同じ JSON 組み立てを流用）

## 5. パッケージ構成（確定）

```
src/
├── graphql/          # M1: lexer, parser, ast, normalized_ast, validation, introspection
├── metadata/         # M2: YAML ロード（merge key 展開）, OpenDD 風型, resolve/検証
├── schema/           # M2: 解決済みメタデータ → GraphQL スキーマ + introspection 応答
├── session/          # M5: role + x-hasura-* 変数（M3 では admin 固定のスタブ）
├── ir/               # M3: 正規化クエリ + 権限 → IR
├── ndc/              # M3: Connector trait, QueryRequest/Response 型（NDC v0.2 サブセット）
├── ndc_postgres/
│   ├── sqlgen/       # M3: QueryRequest → SQL AST → 文字列 + params（純 MoonBit）
│   └── exec/         # M4: SqlExecutor trait + native 実装 / M7: workers 実装
└── server/           # M4: async/http の GraphQL エンドポイント
```

依存方向は上から下のみ。`graphql`〜`sqlgen` までは **native 依存ゼロ**を CI で強制する
（js/wasm-gc での `moon check` を通し続ける）。

## 6. マイルストーン詳細

### M0: scaffold + フィクスチャ取り込み（小）
- `moon new` ベースでモジュール作成（`name = "unacowa/mosura"`、Apache 2.0）、上記パッケージの骨格、依存の追加とバージョン固定
- **§1 の取り込みパイプライン一式**: `scripts/import-fixtures.sh`（コミット固定 clone + 正規化 + .snap 変換）、`fixtures/cases.toml`（全ケースのタグ台帳）、合格率レポータ、NOTICE
- CI: `moon check --target native,js,wasm-gc`（純度チェック）+ `moon test --target native` + `moon fmt --check` + 合格率集計の出力
- E2E 用 `docker-compose.yaml`（PostgreSQL 16）
- **DoD**: CI グリーン、全フィクスチャが取り込まれ `cases.toml` で全件タグ付けされている（この時点で in-scope はゼロ、以降の M で pending → in-scope に移していく）、初回コミット

### M1: GraphQL フロントエンド（大・約 9k LOC 移植）
- lexer → parser → AST（位置情報付きエラー）を lang-graphql から移植
- normalized_ast（variables 展開、fragment 展開、@skip/@include 評価）
- validation（スキーマ照合。schema 型の in-memory 表現も同時に移植）
- introspection クエリの応答生成
- **TDD**: 着手時に lang-graphql フィクスチャ（104 + 46）の in-scope 分を全部レッドで登録してから実装を始める
- **DoD**: lang-graphql フィクスチャの in-scope 100% グリーン

### M2: メタデータ → スキーマ生成（中）
- YAML ローダ（マルチドキュメント、merge key 展開、`urlFromEnv` の環境変数解決、位置情報付きエラー）
- kind セット（§4）の型定義（`FromJson` ベースのデコード）と resolve（名前解決・型整合・リレーション検証）
- スキーマ生成: `query_root` に `<model>`（引数 where/order_by/limit/offset）と `<model>_by_pk`
- **TDD**: metadata-resolve フィクスチャ（289 ケース、passing/failing）のうち §4 の kind セットに該当する分を in-scope 化してから実装。エラーメッセージも failing ケースのスナップショットに合わせる。加えて `engine/tests/execute` の introspection 期待値を使う
- **DoD**: metadata-resolve フィクスチャの in-scope 100% グリーン。GraphiQL（外部ツール）が introspection でスキーマを表示できる（同梱はしない）

### M3: IR + SQL 生成（大）
- IR 型と生成（この時点では admin ロール固定、権限は M5 で注入）
- NDC サブセット型（QueryRequest / Expression / OrderBy / Relationship / RowSet）
- sqlgen: QueryRequest → SQL AST → プリンタ（`$n` パラメータ、識別子クオート、演算子マッピング）
- **TDD**: ndc-postgres translation フィクスチャ（121 ケース、QueryRequest JSON → 期待 SQL）の query 系を in-scope 化してから実装（DB 不要でレッド→グリーンが回る）
- **DoD**: translation フィクスチャの in-scope 100% グリーン

### M4: 実行 + HTTP サーバ（中）
- `SqlExecutor` trait + `exec/native`（moonbit-community/postgres、pgpool 使用、1 リクエスト 1 プール取得）
- `server/`: `POST /graphql`（GraphQL over HTTP 仕様のエラー形式）、`GET /healthz`
- 起動フロー: YAML ロード → resolve → スキーマ構築 → サーバ起動（エラー時は位置付きで異常終了）
- §1 の E2E コンバータ: custom-connector データセット → PG シード SQL + metadata 書き換え
- **TDD**: `engine/tests/execute` の query 系（admin ロール・権限なし）ケースを in-scope 化。PG16 に対してリクエスト → 期待レスポンス一致で判定
- **DoD**: execute フィクスチャ（query 系）の in-scope 100% グリーン。`mosura serve --metadata ./metadata` で実 DB にクエリが通る

### M5: 認証・権限（中）
- session 解決: dev モード（`x-hasura-admin-secret` + ヘッダ直指定）→ JWT HS256（claims から role/変数抽出）
- IR 生成への `ModelPermissions.filter` 注入（セッション変数はパラメータ化）、`TypePermissions` によるフィールド可視性（スキーマ自体もロール別に変わる: V3 同様ロール別スキーマを構築）
- **TDD**: `engine/tests/execute` の permission 系ケース（permission_filter / relationship_predicates 等、session_variables.json 付き）を in-scope 化
- **DoD**: execute フィクスチャ（permission 系）の in-scope 100% グリーン。user ロールが自分の行しか読めない E2E デモ

### M6: ミューテーション + データ制約（中）
- `insert_<model>` / `update_<model>_by_pk` / `delete_<model>_by_pk` の自動生成（V2 風）
- INSERT/UPDATE/DELETE + RETURNING の sqlgen、トランザクション（複数 root field の原子性）
- ArgumentPresets / 入力プリセット（権限による列固定・チェック制約）
- **TDD**: V2 風 CRUD は V3 に対応フィクスチャがないため、自作の SQL ゴールデンで固定する（fixtures/mosura/mutations/ 配下に分離し、移植分と区別する）。ndc-postgres translation の mutations 系ゴールデン (mutation/v2) は SQL 形状 (INSERT の check 制約列等) を採用しないため out-of-scope とする（issue #8 の判断: 現行 CRUD は E2E 検証済みで、~700 行の mutation/v2 移植は SQL 形状互換以外の価値が薄い）
- **DoD**: 自作 CRUD ゴールデン (fixtures/mosura/mutations) の in-scope 100% グリーン
- 注: `update_<model>_by_pk` / `delete_<model>_by_pk` は主キーが定義された Model のみ生成

### M7: Edge / Cloudflare Workers（中）
- コア〜sqlgen の js/wasm-gc ビルドは M0 から CI で担保済みのため、追加は実行系のみ
- `exec/workers`: JS FFI で postgres.js に委譲（Hyperdrive の connectionString を使用）
- `server/workers`: fetch ハンドラアダプタ（async/http の代わり）、メタデータはビルド時同梱（KV/静的 import）
- wrangler サンプルプロジェクトとデプロイ手順
- **TDD**: M4/M5 でグリーンになった execute フィクスチャと同じスイートを Workers ランタイム上で再実行する（実行系だけ差し替えて同じ期待値を使う）
- **DoD**: native でグリーンの in-scope スイートが Workers + Hyperdrive でも 100% グリーン

### 実装順の依存関係

```
M0 ─ M1 ─ M2 ─ M3 ─ M4 ─ M5 ─ M6
                              └─ M7（M4 完了後なら M5/M6 と並行可能）
```

## 7. 確定済みの判断（2026-07-20）

- モジュール名: **`unacowa/mosura`**
- GraphiQL は**同梱しない**（外部 GraphiQL から introspection を叩く）
- 開発方針は TDD（§1）: フィクスチャ先行・合格率を進捗指標とする
