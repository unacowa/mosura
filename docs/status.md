# 開発状況スナップショット (引き継ぎ用)

**最終更新: 2026-07-20** — 大きな節目 (PR マージ、マイルストーン完了、スコープ判断) の
たびにこのファイルを更新すること。日々の正確な状態は GitHub が正:

```sh
gh pr list --repo unacowa/mosura
gh issue list --repo unacowa/mosura
python3 scripts/gen_cases.py   # 台帳集計 (in-scope / pending / out-of-scope)
```

## 完了しているもの (main)

- M0–M7 の初期スコープ一式 (詳細は [implementation-plan.md](implementation-plan.md))
- V3 メタデータ (subgraphs 形式 JSON) 互換ローダ — metadata-resolve passing 68/68 受理、
  failing は Mosura の検証で拒否できる 10 件を回帰固定 (PR #9 / issue #3)
- V3 execute フィクスチャの E2E ハーネス — 21 ケースが V3 期待レスポンスと構造一致、
  `src/e2e/execute_pinned.mbt` に固定 (PR #11 / issue #4)
- 台帳: in-scope 208 全グリーン / pending 334 / out-of-scope 140 (main 時点)

## オープン中の PR (2026-07-20 時点、全て CI グリーン)

マージ推奨順: #12 → #13 → #14 → #15 (#13 と #14 は cases.toml を両方触るが領域は別)。

| PR | Issue | 内容 |
|----|-------|------|
| #12 | #5 | JWT HS256 認証 (claims 抽出、ロール切替、exp 検査。session は pure 維持) |
| #13 | #6 | リレーション跨ぎ order_by (sorting.rs 移植 + schemagen/IR。ゴールデン +6) |
| #14 | #8 | mutation/v2 ゴールデンを out-of-scope 化、自作 CRUD ゴールデン 5 件を固定 |
| #15 | #7 | ロール別ミューテーション権限 (columns / presets / 行フィルタ) |

## オープン中の issue

- #1, #2 — 既知の問題 (CI toolchain のバージョン固定不可など)
- #3–#8 — 全て PR 済み (マージで自動クローズされる)

## 次の作業候補 (未 issue 化のものを含む)

- ミューテーションの複数ルートフィールドのトランザクション原子性 (BEGIN/COMMIT)。
  PR #15 で明示的にスコープ外にした
- order_by の集約対象 (`sorting_by_*_count` ゴールデン)。NDC デコーダと sqlgen の
  aggregate 対応が前提
- V3 execute フィクスチャの追加取り込み: 大文字 enum (`Asc`/`Desc`)、where の
  リレーション filter (`Album: {Artist: {...}}`) など V3 固有の GraphQL 記法対応で
  order_by / where 系のケースがさらに通る見込み
- JWT RS256 (issue #5 のフォローアップ。RSA ライブラリの評価から)
- README のステータス集計はオープン PR のマージ後に更新する (台帳数が動くため)

## 引き継ぎメモ

- 開発フロー・ゴールデン更新手順: [development.md](development.md)
- MoonBit の落とし穴 (必読): [moonbit-notes.md](moonbit-notes.md)
- 移植元クローンの固定コミットは `scripts/import-fixtures.sh` 冒頭の
  `HASURA_COMMIT` / `NDC_PG_COMMIT` が正
