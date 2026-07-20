# Hasura V3 互換性マトリクス

<!-- このファイルは scripts/gen_compat.py が生成する。直接編集せず、スクリプトの FEATURES を編集して再生成すること (CI で freshness チェックされる) -->

Hasura GraphQL Engine V3 の機能に対する Mosura の対応状況。
「根拠」列は [fixtures/cases.toml](../fixtures/cases.toml) の台帳集計 (in-scope = 移植元フィクスチャで同一挙動を CI 強制 / pending = 未昇格 / out-of-scope = 理由付きでスコープ外) と、フィクスチャの無い機能のテスト所在。行をまたぐケースの重複計上は許容している。
この表に無い機能は未対応と考えること。スコープ判断の経緯は [implementation-plan.md](implementation-plan.md) を参照。

## 互換性レベル

| レベル | 意味 |
|--------|------|
| ✅ 互換 | 移植元 (Hasura V3 / ndc-postgres) のフィクスチャで同一挙動を CI 強制 |
| 🟡 部分互換 | サブセットを同一挙動で対応。差異・制限は備考に明記 |
| 🔄 独自実装 | 意図的に Hasura と異なる設計を選択 (経緯は implementation-plan.md) |
| ❌ 未対応 | 将来実装する想定 (Issue または台帳の pending で追跡) |
| 🚫 対象外 | スコープ外と判断 (理由は cases.toml の out-of-scope reason) |

## GraphQL API (クエリ)

| 機能 | 互換性 | 備考 (差異・制限) | 根拠 | 追跡 |
|------|--------|-------------------|------|------|
| GraphQL パース/バリデーション (クエリ・SDL) | ✅ 互換 | lang-graphql の lexer/parser/AST を移植。Rust `{:#?}` 互換のデバッグ出力までバイト一致。out-of-scope はスコープ外機能 (aggregates 等) の SDL ケース | in-scope 93 / out-of-scope 11 | — |
| introspection (`__schema` / `__type` / `__typename`) | 🟡 部分互換 | エンジン実装済み。V3 の execute ゴールデンは未昇格 (V3 固有の応答形状の突き合わせが残) | pending 4 | — |
| モデル select (`where` / `order_by` / `limit` / `offset`) | 🟡 部分互換 | 比較演算子は標準セット (`_eq` `_neq` `_gt` `_gte` `_lt` `_lte` `_in` `_like` `_is_null`)。V3 固有の記法 (enum の大文字 `Asc` 等) が未対応のため pending の execute ケースが残る。out-of-scope はネスト/composite 型・native query 前提のケース | in-scope 19 / pending 80 / out-of-scope 30 | — |
| by_pk 単一取得 | 🟡 部分互換 | V2 風の `<model>_by_pk`。V3 の unique クエリに相当 | src/e2e/e2e_test.mbt | — |
| リレーション (object / array の入れ子選択) | 🟡 部分互換 | 単一コネクタ内のみ (remote relationships は対象外) | in-scope 6 / pending 13 / out-of-scope 8 | — |
| where でのリレーション跨ぎ filter | ❌ 未対応 | NDC/SQL 層 (exists) は対応済み。GraphQL の bool_exp がスカラー比較のみでリレーションフィールドを生成しない | — | — |
| order_by のリレーション跨ぎ | 🟡 部分互換 | object リレーションのみ (LEFT OUTER JOIN LATERAL)。array 越しのカラムソート (要 aggregate) と field_path (ネストフィールド) は明示的に拒否 | in-scope 5 / out-of-scope 4 | — |
| GraphQL 変数 | 🟡 部分互換 | 変数の展開・型検査は対応済み。V3 の execute ゴールデンは未昇格 | pending 6 | — |
| 集約 (aggregates) | 🚫 対象外 | MVP 対象外 | out-of-scope 15 | — |
| Relay (node インターフェース) | ❌ 未対応 | 未対応 (台帳では pending) | pending 9 | — |
| subscriptions | 🚫 対象外 | 対象外。メタデータの allowSubscriptions は読み込みのみ | — | — |

## ミューテーション

| 機能 | 互換性 | 備考 (差異・制限) | 根拠 | 追跡 |
|------|--------|-------------------|------|------|
| ミューテーション機構 | 🔄 独自実装 | V3 の Command 機構は採用せず、V2 風自動 CRUD (`insert_<model>` / `update_<model>_by_pk` / `delete_<model>_by_pk`) を提供。SQL 形状も独自 (CTE + json_agg) で、回帰は自作ゴールデンで固定。複数行 INSERT はカラム集合を先頭行から導出する既知バグあり | in-scope 5 | #20 |
| Command 機構 (commands / functions / procedures) | 🚫 対象外 | 採用しない (V2 風 CRUD を選択。経緯は implementation-plan.md §4) | out-of-scope 33 | — |
| post-write 権限 CHECK / トランザクション分離 | ❌ 未対応 | upstream mutation/v2 が持つ RETURNING `%check__constraint` + bool_and と `BEGIN ISOLATION LEVEL … COMMIT` に相当する機能。未実装 | out-of-scope 8 | #18 |

## 権限・認証

| 機能 | 互換性 | 備考 (差異・制限) | 根拠 | 追跡 |
|------|--------|-------------------|------|------|
| select 行フィルタ (ModelPermissions) | 🟡 部分互換 | fieldComparison / and / or / not のサブセット。値は sessionVariable / literal | in-scope 2 / pending 1; src/e2e/permissions_test.mbt | — |
| カラム可視性 (TypePermissions) | 🟡 部分互換 | allowedFields によるロール別のスキーマ可視性 (見えないフィールドは validation で拒否) | src/schema (Namespaced) / src/e2e/permissions_test.mbt | — |
| ミューテーション権限 (columns / 行フィルタ / presets) | 🔄 独自実装 | V2 の insert/update/delete permissions 風 (V2 風 CRUD に対する権限)。V3 は command permissions + ArgumentPresets なので構造が異なる。権限拒否・セッション変数不足は専用エラーで返る (internal error にしない) | src/e2e/mutation_permissions_test.mbt | — |
| 認証: adminSecret (開発モード) | 🟡 部分互換 | x-hasura-admin-secret 一致で x-hasura-role / x-hasura-* を信頼。AuthConfig があるのに認証方式が無い場合は fail-closed。webhook 認証は対象外 | src/session/jwt_test.mbt | — |
| 認証: JWT | 🟡 部分互換 | HS256 のみ (RS256 / JWKS / webhook モードは未対応)。V2 (`https://hasura.io/jwt/claims`) / V3 (`claims.jwt.hasura.io`) 両名前空間、x-hasura-role によるロール切替、exp / nbf 検査に対応 | src/session/jwt_test.mbt | — |

## メタデータ

| 機能 | 互換性 | 備考 (差異・制限) | 根拠 | 追跡 |
|------|--------|-------------------|------|------|
| Mosura ネイティブ YAML | 🔄 独自実装 | OpenDD の語彙を踏襲したサブセット。ビルドサービスを持たずエンジンが直接ロード・検証する | src/metadata/loader_test.mbt | — |
| V3 metadata.json (subgraphs 形式) の互換ロード | 🟡 部分互換 | v3_compat.mbt。resolved メタデータのスナップショット完全一致は対象外 (意図的サブセット)。pending は未対応 kind の検証ケース | in-scope 78 / pending 211 | — |

## データコネクタ (NDC) / 実行系

| 機能 | 互換性 | 備考 (差異・制限) | 根拠 | 追跡 |
|------|--------|-------------------|------|------|
| NDC 境界 (QueryRequest) | 🟡 部分互換 | NDC 仕様のサブセットに整合。コネクタは in-process (MoonBit trait) で、HTTP / 独立プロセスのコネクタは未対応 | docs/architecture.md | — |
| ndc-postgres SQL 生成 | 🟡 部分互換 | query-engine/translation の移植 (pure)。エイリアス採番・クオートまで移植元ゴールデンと一致。out-of-scope は aggregates / native queries / mutation v2 等 | in-scope 22 / pending 3 / out-of-scope 35 | — |
| PostgreSQL 実行 | 🟡 部分互換 | PG ワイヤプロトコルの native 実装。V3 の execute フィクスチャを PG16 に対して E2E 検証 | in-scope 21 / pending 112 / out-of-scope 96 | — |
| remote relationships (複数コネクタ) | 🚫 対象外 | 対象外。in-scope の 1 件は単一コネクタで完結する基準応答ケース | in-scope 1 / out-of-scope 22 | — |
| native queries | 🚫 対象外 | 対象外 (将来検討) | pending 1 / out-of-scope 5 | — |
| Apollo Federation / JSON:API | 🚫 対象外 | 対象外 | out-of-scope 2 | — |
| plugin hooks (pre/post) | 🚫 対象外 | 対象外。in-scope の集計はプラグイン無し時の基準応答ケース | in-scope 3 / out-of-scope 2 | — |
| Cloudflare Workers (plan/shape 2 フェーズ API) | 🔄 独自実装 | Hasura に無い Mosura 独自機能。pure なコアを Edge で動かすための分割実行 API | src/workers / examples/workers | — |

## 台帳サマリ

全 687 ケース: in-scope 219 / pending 326 / out-of-scope 142 (`python3 scripts/gen_cases.py` の集計と一致)
