# 開発ガイド

日常の開発フロー、フィクスチャ台帳の運用、ゴールデンテストの更新手順。
プロジェクト概要は [../README.md](../README.md)、設計は [architecture.md](architecture.md) を参照。

## セットアップ

```sh
# MoonBit toolchain (配布サーバは latest のみ。バージョン固定不可 → issue #2)
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash

moon update && moon install    # レジストリ更新 + 依存取得 (.mooncakes/)
docker compose up -d           # E2E 用 PostgreSQL 16 (localhost:5433, mosura/mosura/mosura)

# 注意: E2E のコード既定は localhost:5435 の test/test/test (開発用コンテナ前提)。
# docker compose の PG を使うなら環境変数の指定が必須:
export MOSURA_TEST_PG_PORT=5433 MOSURA_TEST_PG_USER=mosura \
       MOSURA_TEST_PG_PASSWORD=mosura MOSURA_TEST_PG_DB=mosura
moon test --target native      # 全テスト
```

接続先の環境変数は `MOSURA_TEST_PG_{HOST,PORT,USER,PASSWORD,DB}`。

## CI が要求すること (ローカルで再現する手順)

`.github/workflows/ci.yml` と同じ順で:

1. `moon check --target native --deny-warn`
2. コア純度: `moon check --target {js,wasm-gc} <コアパッケージ列> --deny-warn`
   (server / cmd / e2e 以外は native 依存を持ち込まない)
3. `moon test --target native` (PG16 サービスに対して E2E も実行)
4. `moon fmt` して diff が出ないこと
5. `python3 scripts/gen_cases.py` して `fixtures/cases.toml` に diff が出ないこと

## フィクスチャ台帳 (TDD の中核)

全テスト資産は `fixtures/` にあり、1 ケース 1 エントリで `fixtures/cases.toml` に登録される。

- タグの意味: `in-scope` (CI でグリーン維持) / `pending` (未実装の M に属する) /
  `out-of-scope` (MVP 対象外。**削除はしない**。reason 必須)
- `scripts/gen_cases.py` が台帳を再生成する。**手動で付けたタグは再生成後も維持される**ので、
  タグ変更は cases.toml を直接編集してから gen_cases.py を再実行して整形する
- 機能を実装したら、通るようになったケースを in-scope へ昇格するのが PR の完成条件

### 取り込み (通常は不要)

`scripts/import-fixtures.sh` が移植元 (hasura/graphql-engine v3, hasura/ndc-postgres) を
**コミット固定**で clone して fixtures/ を再生成する。insta .snap → .expected 変換
(`convert_snaps.py`) と execute 用シード SQL の COPY→INSERT 変換 (`convert_execute_seed.py`) を含む。
既存 checkout を使う場合は `HASURA_SRC=... NDC_PG_SRC=...` (コミット一致を検証される)。

`fixtures/mosura/` 配下だけは Mosura 独自のテスト (移植元に対応が無い機能用) で、手で管理する。

## テストスイートの種類と更新手順

### 1. lang-graphql パーサゴールデン (src/graphql)

Rust の `{:#?}` 出力とバイト一致 (rust_debug.mbt が printer)。失敗時は printer か
パーサの挙動差を疑う。期待ファイルは移植元由来なので編集しない。

### 2. metadata-resolve 受理/拒否 (src/metadata/v3_fixtures_test.mbt)

意味論は「V3 が受理するものを互換ローダも受理できる」(passing/ 68 ケース全部) と、
「V3 が拒否するもののうち Mosura の検証で拒否できる集合を回帰固定」(failing/ の固定リスト)。
resolve 結果スナップショットとのバイト一致は対象外 (Mosura の resolved モデルは意図的にサブセット)。
拒否できるケースが増減したら `v3_failing_rejected` リストを意図を確認して更新する。

### 3. ndc-postgres translation ゴールデン (src/ndc_postgres/sqlgen/goldens_test.mbt)

生成 SQL を空白正規化して比較 (SQL 内容・クオート・**エイリアス採番は完全一致**)。
ハーネスは自動発見: 翻訳が通るようになったケースは即座に期待値と比較されるため、
新機能でケースが「翻訳できるが SQL が違う」状態になると CI が落ちる。
エイリアス採番を合わせるには移植元と同じ順で `state.make_table_alias` を呼ぶ必要がある。

### 4. engine execute E2E (src/e2e/execute_fixtures_test.mbt)

V3 の execute フィクスチャを実 PG で実行し、expected.json と構造比較する。
合格ケースは `src/e2e/execute_pinned.mbt` に固定。**新たに通ったケースはテスト出力に
`NEW-PASS` と出る**ので、確認して固定リストと cases.toml を更新する。
シードは `fixtures/execute-seed/` (冪等: `to_regclass` チェックでスキップ)。

### 5. Mosura 独自 CRUD ゴールデン (fixtures/mosura/mutations)

現行 CRUD の生成 SQL をバイト一致で固定 (issue #8 の判断で mutation/v2 移植はしない)。
期待ファイルが無い/不一致だと実際の出力が println されるので、意図的な変更のときだけ
その出力で expected.sql を更新する。

### 6. Mosura 独自 E2E (src/e2e/*_test.mbt)

実 PG に対する機能テスト。**テーブル名にテスト毎のサフィックス** (`__SFX__` 置換) を
使うこと — テストは並列実行されるため共有テーブルは競合する。

## PR / コミット規約

- feature ブランチ → PR → CI グリーン → squash merge (`gh pr merge --squash --delete-branch`)
- コミットメッセージ・PR は英語。`Closes #N` を本文に含める
- PR には **honest scope** (実装した範囲と、意図的に対象外にした範囲 + 理由) を書く
- スタック PR は避ける (base ブランチ削除で自動クローズされ再オープン不可になった前例 → PR #10/#11)

## Issue のラベルルール (トリアージ)

3 軸 + 補助でラベリングする。新規 Issue は起票時 (遅くともトリアージ時) に **type 1 つ + area 1 つ以上 + priority 1 つ** を付ける。

| 軸 | ラベル | 使い分け |
|----|--------|----------|
| type | `bug` | 実装済み機能が正しく動かない (サイレントな誤動作を含む) |
| | `enhancement` | 新機能・未実装機能の追加 |
| | `security` | セキュリティ・権限の健全性に関わる (type と併用可) |
| | `documentation` | ドキュメントのみ |
| area | `area: graphql` / `area: metadata` / `area: sqlgen` / `area: permissions` / `area: auth` / `area: engine` / `area: toolchain` | パッケージ地図 (CLAUDE.md) に対応。跨る場合は複数付与 |
| priority | `P1` | 最優先: セキュリティ・データ正しさ・サイレント故障 |
| | `P2` | 高: 実利用のブロッカーになり得る。次に着手する |
| | `P3` | 低: 影響が限定的。機会があれば |
| 補助 | `compat` | Hasura V3 との互換性ギャップ ([compatibility.md](compatibility.md) の行と対応させる) |
| | `upstream` | MoonBit ツールチェイン・依存ライブラリ起因 (リポジトリ内では完結しない) |
| | `good first issue` | 修正方針が本文に明記済みで、変更範囲が 1 パッケージに収まるもの |
| | `duplicate` / `wontfix` / `question` 等 | GitHub 既定の運用に従う |

運用メモ:

- `compat` の Issue を閉じたら `scripts/gen_compat.py` の該当行 (追跡列・非対応欄) を更新して再生成する
- 重複はどちらかに集約してクローズ (相互にコメントでリンクを残す)
- priority は「壊れ方の深刻さ」で決める。silent wrong result (黙って誤る) は目に見えるエラーより上げる

## 移植元の参照

移植作業では移植元コードを手元に clone して該当ファイルを読みながら進める:

- hasura/graphql-engine の `/v3` (コミットは `scripts/import-fixtures.sh` の `HASURA_COMMIT`)
- hasura/ndc-postgres (同 `NDC_PG_COMMIT`)

SQL 生成の移植は `crates/query-engine/translation/src/translation/` (query/sorting/filtering/
relationships/root)、対応する Mosura 側は `src/ndc_postgres/sqlgen/translate.mbt`。
