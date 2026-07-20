# 開発状況の見取り図 (引き継ぎ用)

**このファイルは PR/Issue/合格数を列挙しない** — それらは陳腐化するので、常に一次情報を見ること。
ここに書くのは「一次情報を読むためのコマンド」と「一次情報からは読み取れない背景・方針」だけ。

## 一次情報 (これが正)

```sh
gh pr list --repo unacowa/mosura              # 進行中の作業 (レビュー指摘は各 PR のコメント)
gh issue list --repo unacowa/mosura           # 未着手・フォローアップ
python3 scripts/gen_cases.py                  # フィクスチャ台帳の集計 (in-scope/pending/out-of-scope)
git log --oneline -20                         # 直近の変更
```

進捗の一次指標はフィクスチャ合格率 (in-scope 全グリーン)。README のステータス欄の数値は
節目でしか更新しないので、正確な数は `gen_cases.py` の出力を見る。

## 一次情報から読み取れない背景 (ここにしか無い情報)

### 実装の到達点 (マイルストーン粒度)

- M0–M7 の初期スコープは実装済み。エンジンは query (filter/order_by/limit/offset/relationship/
  by_pk/introspection/変数)、ロール別権限 (行フィルタ/カラム制限/スキーマ可視性)、V2 風 CRUD、
  JWT/admin-secret 認証、Cloudflare Workers 用 plan/shape API までをカバーする。
- 詳細なマイルストーン定義とスコープ判断の経緯は [implementation-plan.md](implementation-plan.md)。

### 意図的に対象外にしている領域 (「未実装のバグ」ではなく「やらない/後回し」と決めたもの)

- **Command 機構** — 採用せず V2 風の自動 CRUD を選択 (implementation-plan.md §4)。
- **ndc-postgres mutation/v2 の SQL 形状** — 移植せず自作 CRUD ゴールデンで固定
  (out-of-scope の理由は `fixtures/cases.toml` を参照)。ただし v2 が内包する
  post-write 権限 CHECK とトランザクション分離は**未実装の課題**として残っている。
- **aggregates / subscription / Apollo Federation / JSON:API / remote relationships** — MVP 対象外。
- resolved メタデータのスナップショット完全一致 — Mosura の resolved モデルは意図的にサブセット。

これらは `fixtures/cases.toml` に `out-of-scope` タグと理由付きで記録され、削除されない
(将来解凍できるように)。「対象外」と「未実装のバグ」を混同しないこと。

### 次の作業を探すときの視点

- `gh issue list` のうち、`out-of-scope` の再検討や既存コードのバグは単発で着手しやすい。
- フィクスチャの `pending` を in-scope に昇格するのが本流の進め方。どの機能がどの M に
  属するかは cases.toml の `milestone` タグと implementation-plan.md を突き合わせる。
- V3 の execute フィクスチャは、大文字 enum (`Asc`/`Desc`) や where のリレーション filter など
  V3 固有の GraphQL 記法に対応すると、さらに多くのケースが通るようになる余地がある。

## 引き継ぎ時に読む順

1. [../CLAUDE.md](../CLAUDE.md) — 規約とパッケージ地図
2. [moonbit-notes.md](moonbit-notes.md) — MoonBit の落とし穴 (必読。再発防止集)
3. [development.md](development.md) — 開発フロー・ゴールデン更新手順
4. 上記コマンドで進行中の PR/Issue と台帳の現況を把握する

移植元クローンの固定コミットは `scripts/import-fixtures.sh` 冒頭の
`HASURA_COMMIT` / `NDC_PG_COMMIT` が正。
