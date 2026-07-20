# Mosura

Hasura GraphQL Engine V3 のクエリエンジン部分を **MoonBit** で再実装するプロジェクト。
wasm / JS / ネイティブの複数バックエンドを持つ MoonBit の特性を活かし、Edge を含む様々なランタイムで動く軽量な GraphQL エンジンを目指す。

## ゴール

- YAML 形式のメタデータ（設定ファイル）から GraphQL スキーマを自動生成する
- ロールベースの権限管理（行フィルタ・カラム制限）とデータ制約をメタデータで宣言する
- GraphQL クエリを SQL に変換し、PostgreSQL に対して実行する
- DB レイヤは Hasura V3 の NDC（Native Data Connector）設計を継承し、プラガブルにする

## ノンゴール

- Web UI（コンソール）の移植
- Hasura DDN のメタデータビルドサービスやクラウド機能の再現

## 開発方針：TDD

**この移植の最も重要な合理性は、移植元のテストケースが揃っていることにある。**
Hasura V3 / ndc-postgres のテスト資産（パーサゴールデン、メタデータ解決スナップショット、
E2E 期待レスポンス、SQL 生成スナップショット、計 700 ケース超）をすべて `fixtures/` に取り込み、
実装より先にレッドの状態を作ってからグリーンにする。進捗の一次指標はフィクスチャ合格率。
詳細は [docs/implementation-plan.md](docs/implementation-plan.md) §1。

## 設計上の決定事項

| # | 論点 | 決定 |
|---|------|------|
| 1 | DB 抽象化 | Hasura V3 の NDC 設計を継承。ただしコネクタはまず in-process（MoonBit trait）で実装し、境界は NDC 仕様に揃える |
| 2 | メタデータ形式 | YAML（OpenDD の語彙を踏襲したサブセット）。ビルドサービスは持たず、エンジンが YAML を直接読み込み・検証する |
| 3 | 初期対象 DB | PostgreSQL（`ndc-postgres` 相当を最初のコネクタとして実装） |
| 4 | 初期ターゲットランタイム | PostgreSQL ワイヤプロトコルで直接通信できる環境（TCP ソケットが使えるランタイム）を前提とする。Edge 対応はソケット抽象化の上で後続対応 |

詳細は [docs/architecture.md](docs/architecture.md) を参照。

## ステータス

M0〜M7 の初期スコープ実装済み (2026-07-20)。

- `mosura serve --metadata <yaml>` で GraphQL エンドポイントが起動する (native)
- query (filter / order_by / limit / offset / relationship / by_pk / introspection / 変数)
- ロール別権限 (行フィルタ + カラム制限 + スキーマ可視性)、V2 風 CRUD (admin)
- 認証: 開発モード (adminSecret) と JWT HS256 (`https://hasura.io/jwt/claims` / `claims.jwt.hasura.io` 名前空間、x-hasura-role によるロール切替、exp 検査)
- Cloudflare Workers: plan/shape の 2 フェーズ API ([examples/workers](examples/workers/))
- V3 メタデータ (subgraphs 形式 JSON) の互換ロード + V3 実フィクスチャでの E2E 検証
- フィクスチャ台帳: in-scope 208 全グリーン / pending 334 / out-of-scope 140

```sh
# 起動例
export PG_MAIN_URL="postgres://user:pass@localhost:5432/db"
moon run --target native src/cmd/mosura -- serve --metadata ./metadata.yaml --port 8080
curl -X POST localhost:8080/graphql -d '{"query":"{ articles { id } }"}'
```

## ドキュメント

| ドキュメント | 内容 |
|---|---|
| [docs/architecture.md](docs/architecture.md) | レイヤ構成・NDC 境界・Workers 対応の設計 |
| [docs/implementation-plan.md](docs/implementation-plan.md) | M0–M7 のマイルストーン定義と TDD 戦略 |
| [docs/development.md](docs/development.md) | 開発フロー (fixtures 台帳、ゴールデン更新、E2E、CI) |
| [docs/moonbit-notes.md](docs/moonbit-notes.md) | MoonBit / 依存ライブラリのハマりどころ集 |
| [docs/status.md](docs/status.md) | 開発状況スナップショット (引き継ぎ用) |
| [CLAUDE.md](CLAUDE.md) | AI コーディングエージェント向けの規約とインデックス |

## 参照実装

- [hasura/graphql-engine `/v3`](https://github.com/hasura/graphql-engine/tree/master/v3) — Rust 製 V3 エンジン（Apache 2.0）
  - `lang-graphql` — GraphQL パーサ/バリデータ
  - `metadata-resolve` — メタデータ解決
  - `graphql-ir` — IR 生成（権限の織り込み）
- [hasura/ndc-postgres](https://github.com/hasura/ndc-postgres) — NDC → SQL 生成の参照（Apache 2.0）
- [NDC Specification](https://hasura.github.io/ndc-spec/) — コネクタ境界の仕様
