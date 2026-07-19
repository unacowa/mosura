# 事前検証レポート：Hasura V3 依存分析と MoonBit 実装可能性

実施日: 2026-07-19
環境: moon 0.1.20260713 / moonc v0.10.4 (native, js, wasm-gc で検証)

## 結論

**実装可能。** 最大の懸念だった「標準的なライブラリの全再実装」は不要。
特に最難関と見ていた PostgreSQL ワイヤプロトコルクライアントは、純 MoonBit 実装の
`moonbit-community/postgres` が既に存在し、**ローカル PostgreSQL 16 に対して
SCRAM-SHA-256 認証 + パラメタライズドクエリの E2E 動作を実機確認した**。
再実装が必要なのは GraphQL パーサとエンジン本体のロジックであり、これらは
外部ライブラリに依存しない自己完結したコード（V3 でも自前実装）なので、
MoonBit の成熟度に律速されない。

## 1. Hasura V3 の依存ライブラリ分析

`hasura/graphql-engine` の `/v3`（Rust workspace）を clone して確認した。

### コア crate の規模（テスト除く .rs 行数）

| crate | LOC | Mosura での扱い |
|-------|-----|----------------|
| `graphql/lang-graphql` | 9,910 | **移植対象**（パーサ/バリデータ。外部の GraphQL パーサに依存しない自前実装であることを確認） |
| `graphql/schema` | 5,808 | 移植対象 |
| `graphql/ir` | 5,040 | 移植対象 |
| `graphql/frontend` | 3,624 | 移植対象 |
| `open-dds` | 9,341 | サブセット移植（型定義 + serde derive が大半） |
| `metadata-resolve` | 28,260 | **サブセット移植**（最大の crate だが、大半は網羅的なバリデーションとエラー型。MVP は必要な kind だけ） |
| `plan` / `plan-types` | 9,280 | 移植対象 |
| `execute` | 5,534 | 大幅簡素化（NDC が in-process になるため HTTP クライアント層が消える） |
| `auth` | 7,323 | 初期は簡易版（admin secret + ヘッダ）、JWT は後続 |

### 外部依存の分類と MoonBit 側の対応

| 分類 | Rust 側 | MoonBit 側の対応 | 検証 |
|------|---------|-----------------|------|
| 言語エルゴノミクス | serde, thiserror, derive_more, strum, indexmap, smol_str, itertools, nonempty | 言語機能 + core で代替。`Map` は挿入順を保持することを実機確認（GraphQL レスポンスのフィールド順保証に必須。indexmap 相当が不要） | ✅ |
| JSON | serde_json (preserve_order) | `moonbitlang/core/json` | ✅ |
| YAML | （V3 は不使用。ビルドサービスが担当） | `moonbit-community/yaml`（yaml-rust2 移植）でマルチドキュメントのパースを実機確認。native/js/wasm-gc 全ターゲットでコンパイル可 | ✅ |
| GraphQL パーサ | 自前実装 (lang-graphql) | **移植する（主要な実装作業）**。`eisem/moon_graphql` が存在するが 2026-07-08 公開の v0.1.1 で若すぎるため参考に留める | — |
| HTTP サーバ | axum + tower + tokio | `moonbitlang/async`（socket, TCP/UDP, TaskGroup）の上に最小実装、または `fantix/mmhttp` 等を評価 | 未検証 |
| HTTP クライアント | reqwest（NDC が HTTP サービスのため） | **不要**（NDC を in-process trait にするため） | — |
| DB クライアント | （ndc-postgres 側: sqlx/tokio-postgres） | `moonbit-community/postgres` v0.0.6。純 MoonBit のワイヤプロトコル実装 + openssl バインディングの TLS。tokio-postgres 相当の API（prepare / query / transaction / COPY / pgpool） | ✅ E2E |
| crypto | sha2, base64, blake2 | `gmlewis/sha256`, `PerfectPan/base64` 等。SCRAM は postgres クライアント内蔵のため自前実装不要 | ✅ |
| JWT | jsonwebtoken, jsonwebkey | `RabitLogic/mjwt`, `Tigls/mb-jwt` が存在（成熟度未検証、M5 以降で評価。HS256 は HMAC-SHA256 で自作も可能） | 未検証 |
| regex / uuid / datetime | regex, uuid, chrono | `moonbitlang/regexp`（公式）, `bobzhang/uuidm`, `MINGtoMING/datetime` | 未検証 |
| SQL フロントエンド | datafusion, sqlparser | **スコープ外**（V3 の SQL インターフェース機能用。GraphQL コアには不要） | — |
| テレメトリ | opentelemetry 一式 | 初期スコープ外 | — |
| proc-macro | opendds-derive 等の derive マクロ | MoonBit の `derive(FromJson/ToJson)` + 手書きで代替（ボイラープレート増だが障害ではない） | — |

## 2. 実機検証の内容

scratch プロジェクトで以下を確認（検証コードはセッションの scratchpad `testlab/`）。

1. **YAML**: `kind: Model` / `kind: ObjectType` の 2 ドキュメント YAML を `Yaml::load_from_string` でパース → 成功
2. **PostgreSQL E2E**: `moonbit-community/postgres` で localhost:5435 の PostgreSQL 16
   （scram-sha-256 認証）に接続し、`select version(), (1 + $1::int)` を
   パラメータ付き extended query で実行 → `param query 1+2 = 3` を取得
3. **JSON キー順序**: `Map[String, Json]` → `stringify()` が挿入順を保持 → GraphQL レスポンス整形に使える
4. **ターゲット別コンパイル**:
   - native: 全部通る
   - js / wasm-gc: yaml, sha256 は通る。postgres クライアントは **native 専用**
     （`moonbitlang/async/socket` + C スタブ `secure_random.c` + openssl 依存のため）
5. **async**: `async fn main` + `@async.with_task_group` が動作（現行の moonbitlang/async 0.20.2 には
   `with_event_loop` は無く、`async fn main` が言語側でサポートされる）

## 3. アーキテクチャへの反映

- **pgwire は自前実装しない**。`moonbit-community/postgres` を採用する
  （architecture.md の「pgwire クライアント」節の方針を変更。TLS も verify-full 対応済みでスコープ外にする必要がなくなった）
- NDC 境界より下（`ndc_postgres` + DB クライアント）は **native ターゲット専用**、
  エンジン層（graphql / metadata / schema / ir / plan）は **ターゲット非依存** に保つ。
  この分離は M7（Edge 対応）で js/wasm-gc 用の別コネクタ（HTTP ベース DB 等）を挿す前提と整合する

## 4. リスク

- `moonbit-community/postgres` は v0.0.6 と若く、API 変更の可能性がある（バージョン固定で緩和。
  最悪でも protocol 層のコードは Apache 2.0 で fork 可能）
- `moonbit-community/yaml` は「簡易サブセット」を謳う。アンカー/エイリアス等、
  メタデータで使う機能の網羅性は M2 着手時に要確認
- MoonBit 本体が 0.x（1.0 は 2026 年上半期予定）。破壊的変更は `moon upgrade` 追従コストとして許容する
- moon の新形式 `moon.mod` / `moon.pkg`（非 JSON）は公式ドキュメントより新しく、
  ウェブ上の情報と食い違うことがある
- エコシステムのライブラリは大半が個人メンテ。コア依存（async, core, regexp は公式）以外は
  fork 前提で考える
