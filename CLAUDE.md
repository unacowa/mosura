# CLAUDE.md

Mosura — Hasura GraphQL Engine V3 のクエリエンジンを MoonBit で再実装するプロジェクト。
概要・設計判断は [README.md](README.md) と [docs/architecture.md](docs/architecture.md) を参照。

## コマンド

```sh
moon test --target native              # 全テスト (--target native 必須。E2E は PG が必要)
moon check --target native --deny-warn # lint (CI と同条件。warning はエラー扱い)
moon fmt                               # フォーマッタ (CI で diff チェックされる)
python3 scripts/gen_cases.py           # fixtures/cases.toml 再生成 (CI で freshness チェック)
docker compose up -d                   # E2E 用 PostgreSQL 16 (localhost:5433, mosura/mosura/mosura)
```

E2E の接続先は環境変数 `MOSURA_TEST_PG_{HOST,PORT,USER,PASSWORD,DB}` で上書きできる
(既定: localhost:5433, mosura/mosura/mosura)。

コア純度チェック (server/e2e/cmd 以外は js / wasm-gc でもビルド可能であること):

```sh
CORE="src/graphql src/metadata src/schema src/schemagen src/session src/ir src/ndc_postgres/sqlgen src/ndc_postgres/exec src/engine src/workers"
moon check --target js $CORE --deny-warn
moon check --target wasm-gc $CORE --deny-warn
```

## 絶対に守ること

- **TDD**: 進捗の一次指標はフィクスチャ合格率 (`fixtures/cases.toml` の in-scope 全グリーン)。
  機能を実装したら対応する pending ケースを in-scope に昇格し、合格を固定する。
  台帳運用・ゴールデンの更新手順は [docs/development.md](docs/development.md)
- **`--target native` を常に明示** (`moon.mod` の preferred_target 頼みにしない)
- **deny-warn 前提**: 非推奨 API を使わない。MoonBit 固有の落とし穴は
  [docs/moonbit-notes.md](docs/moonbit-notes.md) を必ず参照 (ハマりの再発防止集)
- **fixtures/ は手で編集しない** (mosura/ 配下と cases.toml のタグを除く)。
  再取り込みは `scripts/import-fixtures.sh` (移植元コミット固定)
- **コミットは英語**・Conventional Commits 風 (`feat(scope): ...`)。PR は `Closes #N` を含め、
  実装範囲と対象外 (honest scope) を明記する。main へ直接 push しない (feature ブランチ + PR + CI)

## いつ何を読むか

| 状況 | ドキュメント |
|------|-------------|
| 開発フロー全般 (fixtures 台帳、ゴールデン更新、E2E、CI) | [docs/development.md](docs/development.md) |
| MoonBit / moon / 依存ライブラリのハマりどころ | [docs/moonbit-notes.md](docs/moonbit-notes.md) |
| 現在の進捗・未着手の作業・引き継ぎ状態 | [docs/status.md](docs/status.md) + `gh issue list` / `gh pr list` |
| レイヤ構成・NDC 境界・Workers 対応の設計 | [docs/architecture.md](docs/architecture.md) |
| マイルストーン定義 (M0–M7) とスコープ判断の経緯 | [docs/implementation-plan.md](docs/implementation-plan.md) |

## パッケージ地図 (依存は上から下のみ)

```
src/graphql        GraphQL lexer/parser/AST (+ Rust {:#?} 互換 printer)
src/metadata       YAML/JSON メタデータのロードと検証 (+ V3 subgraphs 互換ローダ v3_compat.mbt)
src/schema         型システム・正規化 AST・introspection・ロール可視性 (Namespaced)
src/schemagen      メタデータ → GraphQL スキーマ生成 (query_root / mutation_root / 入力型)
src/session        セッション解決 (admin-secret / JWT HS256)。pure — env/時刻はランタイム層が注入
src/ir             正規化オペレーション + 権限 → NDC QueryRequest (plan_operation)
src/ndc_postgres/sqlgen  QueryRequest → SQL (ndc-postgres translation の移植。pure)
src/ndc_postgres/exec    SqlExecutor trait + native 実装 (PG ワイヤプロトコル)
src/engine         execute_request / plan_request / shape_results (レスポンス整形)
src/server         native HTTP サーバ / src/cmd/mosura  CLI / src/workers  Workers 用 plan/shape API
src/e2e            E2E テスト専用パッケージ (native のみ、実 PG に接続)
```
