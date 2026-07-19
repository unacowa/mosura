# Mosura アーキテクチャ

Hasura V3 のレイヤ構成を継承しつつ、単一プロセス（将来的には単一 wasm モジュール）で完結するように再構成する。

## 全体構成

```
                    ┌─────────────────────────────────────────┐
 HTTP Request ────▶ │ server (ランタイムごとのアダプタ)          │
                    ├─────────────────────────────────────────┤
                    │ auth / session (x-hasura-* 変数, role)    │
                    ├─────────────────────────────────────────┤
                    │ graphql   : parse / validate / normalize │
                    │ schema    : メタデータ由来の GraphQL schema│
                    │ ir        : クエリ + 権限 → 中間表現       │
                    │ plan      : IR → NDC QueryRequest         │
                    ├──────────── NDC 境界 (trait) ─────────────┤
                    │ ndc-postgres : QueryRequest → SQL + 実行  │
                    │ pgwire       : PSQL ワイヤプロトコル client │
                    ├─────────────────────────────────────────┤
                    │ runtime-io : socket / crypto / env 抽象   │
                    └─────────────────────────────────────────┘
                                        │ TCP
                                        ▼
                                   PostgreSQL
```

Hasura V3 との対応関係：

| Mosura | Hasura V3 相当 | 備考 |
|--------|----------------|------|
| `graphql` | `lang-graphql` | GraphQL-October2021 準拠のパーサ/バリデータ |
| `metadata` | `metadata-resolve` + ビルドサービス | YAML を直接読む。ビルドサービスは持たない |
| `schema` | `graphql-schema` | 解決済みメタデータから GraphQL スキーマ生成 |
| `ir` / `plan` | `graphql-ir` / `execute` | 権限（行フィルタ・カラム制限）を IR 生成時に織り込む |
| `ndc` (trait) | NDC 仕様 (HTTP) | in-process trait として実装。仕様の語彙は NDC v0.2 サブセットに揃える |
| `ndc-postgres` | `hasura/ndc-postgres` | SQL 生成 + 実行 |
| `pgwire` | (tokio-postgres 相当) | MoonBit で自前実装 |

## パッケージ構成（予定）

```
Mosura/
├── moon.mod.json
├── src/
│   ├── graphql/        # lexer, parser, AST, validation
│   ├── metadata/       # YAML パース, OpenDD 風オブジェクトの解決・検証
│   ├── schema/         # GraphQL スキーマ生成 + introspection
│   ├── session/        # ロール・セッション変数 (x-hasura-*)
│   ├── ir/             # 正規化済みクエリ + 権限 → IR
│   ├── ndc/            # コネクタ trait と QueryRequest/QueryResponse 型
│   ├── ndc_postgres/
│   │   ├── sqlgen/     # NDC → SQL 生成（純 MoonBit・ターゲット非依存）
│   │   └── exec/       # 実行トランスポート trait + native 実装（moonbit-community/postgres）
│   ├── runtime/        # socket / crypto などランタイム I/O の抽象 interface
│   └── server/         # HTTP エンドポイント (ランタイムごとの実装)
└── docs/
```

## NDC 境界の設計

Hasura V3 では NDC コネクタは独立した HTTP サービスだが、Mosura では **in-process の trait** として実装する。
これにより Edge 環境で単一モジュールとして動かせる。ただし型・語彙（`QueryRequest`, `Expression`,
`Relationship`, `RowSet` など）は NDC v0.2 のサブセットに揃え、将来 out-of-process コネクタ
（HTTP 経由）を追加できる余地を残す。

```
trait Connector {
  capabilities() -> Capabilities
  get_schema()   -> SchemaResponse
  query(QueryRequest)    -> QueryResponse
  mutation(MutationRequest) -> MutationResponse
}
```

初期実装で対象とする NDC 機能サブセット：

- query: フィールド選択, where (comparison/and/or/not), order_by, limit/offset
- relationships: object / array（SQL 上は LATERAL JOIN + JSON 集約）
- aggregates, mutation は後続マイルストーン

## メタデータ（YAML）

OpenDD の `kind`/`version` 語彙を踏襲したサブセット。HML と同様に 1 ファイルに複数ドキュメント
（`---` 区切り）を許容する。エンジン起動時に全ファイルを読み込み・解決・検証する。

```yaml
kind: ObjectType
version: v1
definition:
  name: article
  fields:
    - name: id
      type: Int!
    - name: title
      type: String!
    - name: author_id
      type: Int!
---
kind: Model
version: v1
definition:
  name: articles
  objectType: article
  source:
    dataConnectorName: pg_main
    collection: articles
  filterableFields: [id, title, author_id]
  orderableFields: [id, title]
---
kind: ModelPermissions
version: v1
definition:
  modelName: articles
  permissions:
    - role: user
      select:
        filter:
          fieldComparison:
            field: author_id
            operator: _eq
            value:
              sessionVariable: x-hasura-user-id
---
kind: DataConnectorLink
version: v1
definition:
  name: pg_main
  connector: postgres
  connection:
    # 直値 or 環境変数参照
    urlFromEnv: PG_MAIN_URL
```

権限モデルは Hasura を踏襲する：

- **ModelPermissions** — ロールごとの行レベルフィルタ（セッション変数参照可）
- **TypePermissions** — ロールごとの出力/入力カラム制限
- **ArgumentPresets / データ制約** — 入力値の固定・検証（後続マイルストーン）

## セッションと認証

Hasura 同様、リクエストごとに `role` とセッション変数（`x-hasura-user-id` 等）の集合を確定し、
IR 生成時に権限フィルタとして SQL 述語へ変換する。初期は開発用ヘッダ方式
（`x-hasura-admin-secret` + `x-hasura-role` ヘッダ）から始め、JWT モードを後続で追加する。

## クエリ実行パイプライン

```
GraphQL request
  → parse / validate（スキーマ照合, 変数展開）
  → IR 生成（この時点でロールの行フィルタ・カラム制限を織り込む）
  → plan: NDC QueryRequest に変換（NDC 境界）
  → ndc-postgres: SQL 生成（パラメタライズドクエリ, 1 リクエスト = 原則 1 SQL）
  → pgwire: extended query protocol で実行
  → RowSet → GraphQL レスポンス整形
```

SQL 生成は ndc-postgres と同様、ネストしたリレーションを LATERAL JOIN + `json_agg` /
`row_to_json` で単一クエリに畳み込む方式を採る（N+1 回避）。

## ndc_postgres：SQL 生成と実行トランスポートの分離

`ndc_postgres` は内部を 2 層に分ける（2026-07-20 決定）。

```
ndc_postgres/
├── sqlgen/   NDC QueryRequest → SQL 文字列 + パラメータ列
│             純 MoonBit・ターゲット非依存。ゴールデンテストで DB なし検証可能
└── exec/     trait SqlExecutor { execute(sql, params) -> Rows }
              実行トランスポート。ランタイムごとに差し替える
```

`SqlExecutor` の実装は当面 native のみとし、後続で Edge 用実装を追加できるようにしておく：

| 実装 | ランタイム | 状態 |
|------|-----------|------|
| `exec/native` — `moonbit-community/postgres` | native（TCP 直結） | **初期実装** |
| `exec/workers` — Hyperdrive + JS ドライバ（postgres.js 等）へ FFI 委譲 | Cloudflare Workers (js) | M7 で対応予定 |

Workers + Hyperdrive の場合も PSQL ワイヤプロトコルで話すこと自体は変わらず
（Hyperdrive がプーリング・オリジンへの TLS・prepared statement 管理を肩代わりする）、
差し替わるのは実行部だけ。SQL 生成は全ランタイムで共有される。

### native 実行トランスポート：moonbit-community/postgres

**自前実装せず `moonbit-community/postgres` を採用する**（2026-07-19 の事前検証で決定。
詳細は [feasibility-check.md](feasibility-check.md)）。純 MoonBit のワイヤプロトコル実装で、
SCRAM-SHA-256（channel binding 対応）、extended query、prepared statements、トランザクション、
TLS（openssl バインディング、verify-full 対応）、コネクションプール（pgpool）を備え、
実 PostgreSQL 16 への E2E 動作を確認済み。

注意点：

- `moonbitlang/async/socket` と C スタブに依存するため **native ターゲット専用**。
  エンジン層（graphql / metadata / schema / ir / plan）と `sqlgen` はターゲット非依存に保ち、
  native 依存は `exec/native` に閉じ込める
- v0.0.6 と若いためバージョンを固定する。Apache 2.0 なので最悪 fork 可能

## マイルストーン

| M | 内容 | 完了条件 |
|---|------|----------|
| M0 | リポジトリ整備 | moon プロジェクト scaffold, CI, git 管理 |
| M1 | GraphQL フロントエンド | パーサ/バリデータが graphql-js 相当のテストケースを通る |
| M2 | メタデータ → スキーマ | YAML から introspection 可能な GraphQL スキーマが生成される |
| M3 | クエリ → SQL | admin ロールで SELECT（filter/order/limit/リレーション）の SQL が生成される（実 DB なし, ゴールデンテスト） |
| M4 | pgwire | 実 PostgreSQL に対して end-to-end でクエリが返る |
| M5 | 権限 | ModelPermissions / TypePermissions がロールごとに効く |
| M6 | ミューテーション / 制約 | insert/update/delete + ArgumentPresets |
| M7 | Edge 対応 | js/wasm-gc ターゲットでのビルド + `exec/workers`（Hyperdrive + JS ドライバ委譲）で Workers 上で動作 |

## 未決事項

2026-07-20 の事前スパイクでほぼ解消（詳細は [implementation-plan.md](implementation-plan.md) §0）。

- ~~async/IO~~ → `async fn main` + `with_task_group` で動作確認。HTTP サーバも `async/http` に内蔵
- ~~SCRAM crypto~~ → postgres クライアントに内蔵
- ~~YAML パーサ~~ → `moonbit-community/yaml` で十分（マージキー `<<:` のみ未対応 → loader で Json 後処理）
- ~~ライセンス~~ → Apache 2.0（移植元と整合、NOTICE で帰属）
- HML 互換度 → OpenDD の語彙（kind/version）を踏襲した独自サブセットで確定。完全互換は追わない
- ~~モジュール名~~ → `unacowa/mosura` で確定。~~GraphiQL 同梱~~ → 同梱しない（2026-07-20 確定、implementation-plan.md §7）
- 開発方針は TDD：V3 / ndc-postgres のテスト資産を全量取り込み、フィクスチャ合格率を進捗指標とする（implementation-plan.md §1）
