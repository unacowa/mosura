# Hasura V3 互換性マトリクス

<!-- このファイルは scripts/gen_compat.py が生成する。直接編集せず、スクリプトの FEATURES を編集して再生成すること (CI で freshness チェックされる) -->

Hasura GraphQL Engine V3 の機能に対する Mosura の対応状況。「対応」列が互換に使える範囲、「非対応 / 差異」列が使えない・挙動が異なる範囲で、両列の間が互換性の境界。
「根拠」列は [fixtures/cases.toml](../fixtures/cases.toml) の台帳集計 (in-scope = 移植元フィクスチャで同一挙動を CI 強制 / pending = 未昇格 / out-of-scope = 理由付きでスコープ外) と、フィクスチャの無い機能のテスト所在。行をまたぐケースの重複計上は許容している。
この表に無い機能は未対応と考えること。スコープ判断の経緯は [implementation-plan.md](implementation-plan.md) を参照。

## 互換性レベル

| レベル | 意味 |
|--------|------|
| ✅ 互換 | 移植元 (Hasura V3 / ndc-postgres) のフィクスチャで同一挙動を CI 強制 |
| 🟡 部分互換 | サブセットを同一挙動で対応。境界は「対応」「非対応 / 差異」列に明記 |
| 🔄 独自実装 | 意図的に Hasura と異なる設計を選択 (経緯は implementation-plan.md) |
| ❌ 未対応 | 将来実装する想定 (Issue または台帳の pending で追跡) |
| 🚫 対象外 | スコープ外と判断 (理由は cases.toml の out-of-scope reason) |

## GraphQL API (クエリ)

| 機能 | 互換性 | 対応 | 非対応 / 差異 | 根拠 | 追跡 |
|------|--------|------|---------------|------|------|
| GraphQL パース/バリデーション | ✅ 互換 | クエリ・SDL の構文パースと AST 構築。Rust `{:#?}` 互換のデバッグ出力までバイト一致 | SDL の directive 定義・type extension・supergraph 構文 (out-of-scope 11 件)。`@include` / `@skip` は実行時に評価されない | in-scope 93 / out-of-scope 11 | #37 |
| introspection | 🟡 部分互換 | `__schema` / `__type` / `__typename`。型・フィールド・入力型・enum をロール別可視性込みで返す | V3 ゴールデンとの応答バイト一致は未検証 (pending 4)。GraphqlConfig による introspection カスタマイズ | pending 4 | — |
| モデル select | 🟡 部分互換 | `where` (スカラー比較 `_eq` `_neq` `_gt` `_gte` `_lt` `_lte` `_in` `_like` `_is_null` と `_and` / `_or` / `_not`)、`order_by`、`limit` / `offset`、エイリアス・複数ルートフィールド | テキスト検索演算子は `_like` のみ (`_ilike` `_regex` `_similar` 等は未実装)。order_by 方向は V2 系 6 値 enum (`asc` … `desc_nulls_last`) — V3 の `Asc`/`Desc` 2 値とは記法非互換で、null 配置も固定でない。1 つの order_by オブジェクトに複数キーを書いてもエラーにしない (V3 はエラー)。ネスト/composite/配列型カラム、model arguments、native query 前提のモデル | in-scope 19 / pending 80 / out-of-scope 30 | #33, #34, #36 |
| by_pk 単一取得 | 🟡 部分互換 | `<model>_by_pk` (複合主キー可)。ロール可視性・行フィルタ適用 | V3 の selectUniques 相当 (主キー以外の unique キー、カスタムフィールド名) | src/e2e/e2e_test.mbt | — |
| リレーション (入れ子選択) | 🟡 部分互換 | object / array リレーションの入れ子選択。array 側は `where` / `order_by` / `limit` / `offset` 引数付き。対象モデルのロール可視性と行フィルタを適用 | 複数コネクタ跨ぎ (remote relationships)、リレーション先の aggregates | in-scope 6 / pending 13 / out-of-scope 8 | — |
| where のリレーション跨ぎ filter | ❌ 未対応 | なし (GraphQL からは書けない) | bool_exp にリレーションフィールドが生成されない。NDC/SQL 層の exists 変換は実装済みで、bool_exp 生成と IR 配線のみが残作業 | — | #32 |
| order_by のリレーション跨ぎ | 🟡 部分互換 | object リレーション経由のカラムソート (複数カラム・複数経路、同一経路の JOIN 共有、経路上の predicate) | array リレーション越しのカラムソート (要 aggregate — 明示的に拒否)、field_path によるネストフィールドソート (拒否)、relationship count でのソート (拒否) | in-scope 5 / out-of-scope 4 | — |
| GraphQL 変数 | 🟡 部分互換 | クエリ変数の展開と型検査 (自前 E2E で検証) | V3 execute ゴールデン 6 件は未昇格 (V3 との応答一致は未検証) | pending 6 | — |
| 集約 (aggregates) | 🚫 対象外 | なし | 集約クエリ・集約フィールド・集約 predicate のすべて (MVP 対象外) | out-of-scope 15 | — |
| Relay | ❌ 未対応 | なし | node インターフェース・global ID (台帳では pending) | pending 9 | — |
| subscriptions | 🚫 対象外 | なし | すべて。メタデータの allowSubscriptions は読み込むが機能しない | — | — |

## ミューテーション

| 機能 | 互換性 | 対応 | 非対応 / 差異 | 根拠 | 追跡 |
|------|--------|------|---------------|------|------|
| 自動 CRUD (V2 風) | 🔄 独自実装 | `insert_<model>` (複数行、省略カラムは DEFAULT)、`update_<model>_by_pk` (`_set`)、`delete_<model>_by_pk`、`affected_rows` / `returning` | V3 の Command ベース mutation とはスキーマ非互換 (意図的)。V2 と比べても `on_conflict` (upsert)、`_inc` 等の更新演算子、`update_<model>` / `delete_<model>` (where 一括)、`insert_<model>_one` は無い。SQL 形状も独自 (CTE + json_agg)。複数行 INSERT のカラム集合が先頭行由来 (#20) | in-scope 7 | #20 |
| Command 機構 (commands / functions / procedures) | 🚫 対象外 | なし | すべて (V2 風 CRUD を選択。経緯は implementation-plan.md §4) | out-of-scope 33 | — |
| post-write 権限 CHECK / トランザクション分離 | 🔄 独自実装 | insert / update 権限の `check` 述語 (filter と同じ JSON 形式) を書き込み後の行に適用し、違反があればリクエスト全体をエラー + ROLLBACK。ミューテーションを含むリクエストは単一トランザクション (BEGIN ISOLATION LEVEL READ COMMITTED) で実行され、複数 root フィールドの途中失敗で全体が巻き戻る | SQL 形状は upstream mutation/v2 (`%check__constraint` + bool_and) と異なる独自実装 (`%check__violation` フラグ + engine 側 ROLLBACK)。分離レベルのリクエスト毎指定は不可 (READ COMMITTED 固定)。Workers の plan/shape 経路はトランザクション・違反判定を行わない (呼び出し側責務) | in-scope 7 | — |

## 権限・認証

| 機能 | 互換性 | 対応 | 非対応 / 差異 | 根拠 | 追跡 |
|------|--------|------|---------------|------|------|
| select 行フィルタ (ModelPermissions) | 🟡 部分互換 | `fieldComparison` (field / operator / value) と `and` / `or` / `not`。値は `sessionVariable` / `literal`。WHERE への AND 合成はルート・入れ子とも適用 | リレーションを跨ぐ filter 条件、ネストフィールド条件、V3 の rules-based permissions (v3_compat では skip される) | in-scope 2 / pending 1; src/e2e/permissions_test.mbt | #38 |
| カラム可視性 (TypePermissions) | 🟡 部分互換 | allowedFields によるロール別の出力フィールド可視性 (不可視フィールドの参照は validation エラー) | 入力型はここでは制御しない (ModelPermissions の columns / presets 側)。V3 の rules-based permissions は skip される | src/schema (Namespaced) / src/e2e/permissions_test.mbt | — |
| ミューテーション権限 | 🔄 独自実装 | insert / update の columns 制限と presets (sessionVariable / literal)、update / delete の行フィルタ、insert / update の post-write `check` 述語 (違反時は全体を ROLLBACK)、ロール別のルートフィールド・入力フィールド可視性、権限拒否・セッション変数不足の専用エラー (fail-closed) | V3 の command permissions / ArgumentPresets 形式のメタデータ (対象が V2 風 CRUD なので構造が異なる) | src/e2e/mutation_permissions_test.mbt | — |
| 認証: adminSecret (開発モード) | 🟡 部分互換 | `x-hasura-admin-secret` 一致で `x-hasura-role` / `x-hasura-*` を信頼。AuthConfig 省略時は全リクエスト admin (V3 の noAuth 相当)。AuthConfig があるのに認証方式が無い場合は fail-closed で拒否 | webhook 認証モード | src/session/jwt_test.mbt | — |
| 認証: JWT | 🟡 部分互換 | HS256 署名検証 (定数時間比較)、V2 (`https://hasura.io/jwt/claims`) / V3 (`claims.jwt.hasura.io`) 両 claims 名前空間、default-role / allowed-roles、`x-hasura-role` ヘッダによるロール切替、`x-hasura-*` claim のセッション変数化、exp / nbf 検査 | RS256 / ES256 等の非対称鍵、JWKS URL、audience / issuer 検査、文字列化 (stringified JSON) claims、claims_map / claims 位置のカスタマイズ、webhook モード | src/session/jwt_test.mbt | #41 |

## メタデータ

| 機能 | 互換性 | 対応 | 非対応 / 差異 | 根拠 | 追跡 |
|------|--------|------|---------------|------|------|
| Mosura ネイティブ YAML | 🔄 独自実装 | kind: DataConnectorLink / ObjectType / Model / Relationship / ModelPermissions / TypePermissions / AuthConfig (OpenDD の語彙を踏襲) | 上記以外の OpenDD kind。DDN ビルドサービス・supergraph 合成は持たない (エンジンが YAML を直接ロード・検証) | src/metadata/loader_test.mbt | — |
| V3 metadata.json (subgraphs 形式) の互換ロード | 🟡 部分互換 | ObjectType / Model / Relationship / ModelPermissions / TypePermissions / DataConnectorLink を変換。filter 解決は新形式 BooleanExpressionType (object operand の comparableFields) と旧 ObjectBooleanExpressionType の両対応で、解決できない filterExpressionType は fail-closed でロードエラー (サイレントにフィルタを落とさない)。未定義 connector のスタブ生成 | BooleanExpressionType の comparableRelationships (リレーション述語 — #32/#38)。Command 系 Relationship、rules-based permissions、Model v2 / OrderByExpression / GraphqlConfig 等の kind は skip。resolved スナップショット完全一致 (pending 211) | in-scope 78 / pending 211 | #35, #40 |

## データコネクタ (NDC) / 実行系

| 機能 | 互換性 | 対応 | 非対応 / 差異 | 根拠 | 追跡 |
|------|--------|------|---------------|------|------|
| NDC 境界 (QueryRequest) | 🟡 部分互換 | QueryRequest サブセット (fields / predicate / order_by / limit / offset / variables / collection_relationships) を in-process trait 越しに使用 | NDC HTTP プロトコル (独立プロセスのコネクタ)、capabilities ネゴシエーション。MutationRequest は使わない (ミューテーションは NDC を通さず SQL を直接生成) | docs/architecture.md | — |
| ndc-postgres SQL 生成 | 🟡 部分互換 | select / filter / sort / relationship / variables 系の SQL を移植ゴールデンとバイト一致で生成 (エイリアス採番・クオート含む) | aggregates、native queries、ネスト/composite/配列型、mutation v2 の SQL 形状 | in-scope 22 / pending 3 / out-of-scope 35 | — |
| PostgreSQL 実行 | 🟡 部分互換 | PG ワイヤプロトコルの native 実装で V3 execute フィクスチャの応答一致を PG16 に対して E2E 検証 | pending 112 件は未昇格 (V3 記法・上記機能ギャップに依存)。エラー応答は internal error に詳細メッセージを含む (V3 は "internal error" のみ) | in-scope 21 / pending 112 / out-of-scope 96 | #39 |
| remote relationships (複数コネクタ) | 🚫 対象外 | なし | すべて (in-scope 1 件は単一コネクタで完結する基準応答ケース) | in-scope 1 / out-of-scope 22 | — |
| native queries | 🚫 対象外 | なし | すべて (将来検討) | pending 1 / out-of-scope 5 | — |
| Apollo Federation / JSON:API | 🚫 対象外 | なし | すべて | out-of-scope 2 | — |
| plugin hooks (pre/post) | 🚫 対象外 | なし | すべて (in-scope 3 件はプラグイン無し時の基準応答ケース) | in-scope 3 / out-of-scope 2 | — |
| Cloudflare Workers (plan/shape 2 フェーズ API) | 🔄 独自実装 | pure なコアを Edge で動かすための分割実行 API (Mosura 独自) | Hasura に対応する機能は無い | src/workers / examples/workers | — |

## 台帳サマリ

全 689 ケース: in-scope 221 / pending 326 / out-of-scope 142 (`python3 scripts/gen_cases.py` の集計と一致)
