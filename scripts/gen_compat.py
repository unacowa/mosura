#!/usr/bin/env python3
"""docs/compatibility.md (Hasura V3 互換性マトリクス) を生成する。

- 行 (機能・互換性レベル・備考) はこのファイルの FEATURES を編集して再生成する
- 各行の「根拠」列は fixtures/cases.toml のタグ集計から自動算出される
- CI が再生成して diff が無いことをチェックする (cases.toml と同じ freshness 運用)

互換性レベルの判定方針:
- full    (✅ 互換)     : 移植元のフィクスチャ/ゴールデンで同一挙動を CI 強制している
- partial (🟡 部分互換) : サブセットを同一挙動で対応。差異・制限は備考に明記
- own     (🔄 独自実装) : 意図的に Hasura と異なる設計を選択 (経緯は implementation-plan.md)
- todo    (❌ 未対応)   : 将来実装する想定 (Issue または pending タグで追跡)
- oos     (🚫 対象外)   : スコープ外と判断 (理由は cases.toml の out-of-scope reason)
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
CASES = ROOT / "fixtures" / "cases.toml"
OUT = ROOT / "docs" / "compatibility.md"

LEVELS = {
    "full": "✅ 互換",
    "partial": "🟡 部分互換",
    "own": "🔄 独自実装",
    "todo": "❌ 未対応",
    "oos": "🚫 対象外",
}

LEVEL_LEGEND = [
    ("✅ 互換", "移植元 (Hasura V3 / ndc-postgres) のフィクスチャで同一挙動を CI 強制"),
    ("🟡 部分互換", "サブセットを同一挙動で対応。差異・制限は備考に明記"),
    ("🔄 独自実装", "意図的に Hasura と異なる設計を選択 (経緯は implementation-plan.md)"),
    ("❌ 未対応", "将来実装する想定 (Issue または台帳の pending で追跡)"),
    ("🚫 対象外", "スコープ外と判断 (理由は cases.toml の out-of-scope reason)"),
]

# feature: 機能名 / level: LEVELS のキー / notes: 差異・制限
# patterns: cases.toml のケース ID にマッチする正規表現 (集計対象。行間の重複は許容)
# extra: フィクスチャ以外の根拠 (テストファイル等) / issues: 追跡 Issue
FEATURES = [
    ("GraphQL API (クエリ)", [
        dict(
            feature="GraphQL パース/バリデーション (クエリ・SDL)",
            level="full",
            notes="lang-graphql の lexer/parser/AST を移植。Rust `{:#?}` 互換のデバッグ出力までバイト一致。"
            "out-of-scope はスコープ外機能 (aggregates 等) の SDL ケース",
            patterns=[r"^lang-graphql/"],
        ),
        dict(
            feature="introspection (`__schema` / `__type` / `__typename`)",
            level="partial",
            notes="エンジン実装済み。V3 の execute ゴールデンは未昇格 (V3 固有の応答形状の突き合わせが残)",
            patterns=[r"introspection"],
        ),
        dict(
            feature="モデル select (`where` / `order_by` / `limit` / `offset`)",
            level="partial",
            notes="比較演算子は標準セット (`_eq` `_neq` `_gt` `_gte` `_lt` `_lte` `_in` `_like` `_is_null`)。"
            "V3 固有の記法 (enum の大文字 `Asc` 等) が未対応のため pending の execute ケースが残る。"
            "out-of-scope はネスト/composite 型・native query 前提のケース",
            patterns=[r"^execute/models/", r"^ndc-postgres-translation/goldenfiles/select_"],
        ),
        dict(
            feature="by_pk 単一取得",
            level="partial",
            notes="V2 風の `<model>_by_pk`。V3 の unique クエリに相当",
            extra="src/e2e/e2e_test.mbt",
        ),
        dict(
            feature="リレーション (object / array の入れ子選択)",
            level="partial",
            notes="単一コネクタ内のみ (remote relationships は対象外)",
            patterns=[r"^execute/relationships/"],
        ),
        dict(
            feature="where でのリレーション跨ぎ filter",
            level="todo",
            notes="NDC/SQL 層 (exists) は対応済み。GraphQL の bool_exp がスカラー比較のみでリレーションフィールドを生成しない",
        ),
        dict(
            feature="order_by のリレーション跨ぎ",
            level="partial",
            notes="object リレーションのみ (LEFT OUTER JOIN LATERAL)。"
            "array 越しのカラムソート (要 aggregate) と field_path (ネストフィールド) は明示的に拒否",
            patterns=[r"^ndc-postgres-translation/goldenfiles/sorting_"],
        ),
        dict(
            feature="GraphQL 変数",
            level="partial",
            notes="変数の展開・型検査は対応済み。V3 の execute ゴールデンは未昇格",
            patterns=[r"^execute/variables/"],
        ),
        dict(
            feature="集約 (aggregates)",
            level="oos",
            notes="MVP 対象外",
            patterns=[r"^execute/aggregates/", r"^ndc-postgres-translation/goldenfiles/aggregate"],
        ),
        dict(
            feature="Relay (node インターフェース)",
            level="todo",
            notes="未対応 (台帳では pending)",
            patterns=[r"^execute/relay/"],
        ),
        dict(
            feature="subscriptions",
            level="oos",
            notes="対象外。メタデータの allowSubscriptions は読み込みのみ",
        ),
    ]),
    ("ミューテーション", [
        dict(
            feature="ミューテーション機構",
            level="own",
            notes="V3 の Command 機構は採用せず、V2 風自動 CRUD "
            "(`insert_<model>` / `update_<model>_by_pk` / `delete_<model>_by_pk`) を提供。"
            "SQL 形状も独自 (CTE + json_agg) で、回帰は自作ゴールデンで固定。"
            "複数行 INSERT はカラム集合を先頭行から導出する既知バグあり",
            patterns=[r"^mosura/mutations/"],
            issues=["#20"],
        ),
        dict(
            feature="Command 機構 (commands / functions / procedures)",
            level="oos",
            notes="採用しない (V2 風 CRUD を選択。経緯は implementation-plan.md §4)",
            patterns=[r"^execute/commands/"],
        ),
        dict(
            feature="post-write 権限 CHECK / トランザクション分離",
            level="todo",
            notes="upstream mutation/v2 が持つ RETURNING `%check__constraint` + bool_and と "
            "`BEGIN ISOLATION LEVEL … COMMIT` に相当する機能。未実装",
            patterns=[r"^ndc-postgres-translation/goldenfiles/mutations/"],
            issues=["#18"],
        ),
    ]),
    ("権限・認証", [
        dict(
            feature="select 行フィルタ (ModelPermissions)",
            level="partial",
            notes="fieldComparison / and / or / not のサブセット。値は sessionVariable / literal",
            patterns=[r"^execute/session_variables/"],
            extra="src/e2e/permissions_test.mbt",
        ),
        dict(
            feature="カラム可視性 (TypePermissions)",
            level="partial",
            notes="allowedFields によるロール別のスキーマ可視性 (見えないフィールドは validation で拒否)",
            extra="src/schema (Namespaced) / src/e2e/permissions_test.mbt",
        ),
        dict(
            feature="ミューテーション権限 (columns / 行フィルタ / presets)",
            level="own",
            notes="V2 の insert/update/delete permissions 風 (V2 風 CRUD に対する権限)。"
            "V3 は command permissions + ArgumentPresets なので構造が異なる。"
            "権限拒否・セッション変数不足は専用エラーで返る (internal error にしない)",
            extra="src/e2e/mutation_permissions_test.mbt",
        ),
        dict(
            feature="認証: adminSecret (開発モード)",
            level="partial",
            notes="x-hasura-admin-secret 一致で x-hasura-role / x-hasura-* を信頼。"
            "AuthConfig があるのに認証方式が無い場合は fail-closed。webhook 認証は対象外",
            extra="src/session/jwt_test.mbt",
        ),
        dict(
            feature="認証: JWT",
            level="partial",
            notes="HS256 のみ (RS256 / JWKS / webhook モードは未対応)。"
            "V2 (`https://hasura.io/jwt/claims`) / V3 (`claims.jwt.hasura.io`) 両名前空間、"
            "x-hasura-role によるロール切替、exp / nbf 検査に対応",
            extra="src/session/jwt_test.mbt",
        ),
    ]),
    ("メタデータ", [
        dict(
            feature="Mosura ネイティブ YAML",
            level="own",
            notes="OpenDD の語彙を踏襲したサブセット。ビルドサービスを持たずエンジンが直接ロード・検証する",
            extra="src/metadata/loader_test.mbt",
        ),
        dict(
            feature="V3 metadata.json (subgraphs 形式) の互換ロード",
            level="partial",
            notes="v3_compat.mbt。resolved メタデータのスナップショット完全一致は対象外 (意図的サブセット)。"
            "pending は未対応 kind の検証ケース",
            patterns=[r"^metadata-resolve/"],
        ),
    ]),
    ("データコネクタ (NDC) / 実行系", [
        dict(
            feature="NDC 境界 (QueryRequest)",
            level="partial",
            notes="NDC 仕様のサブセットに整合。コネクタは in-process (MoonBit trait) で、"
            "HTTP / 独立プロセスのコネクタは未対応",
            extra="docs/architecture.md",
        ),
        dict(
            feature="ndc-postgres SQL 生成",
            level="partial",
            notes="query-engine/translation の移植 (pure)。エイリアス採番・クオートまで移植元ゴールデンと一致。"
            "out-of-scope は aggregates / native queries / mutation v2 等",
            patterns=[r"^ndc-postgres-translation/goldenfiles/"],
        ),
        dict(
            feature="PostgreSQL 実行",
            level="partial",
            notes="PG ワイヤプロトコルの native 実装。V3 の execute フィクスチャを PG16 に対して E2E 検証",
            patterns=[r"^execute/"],
        ),
        dict(
            feature="remote relationships (複数コネクタ)",
            level="oos",
            notes="対象外。in-scope の 1 件は単一コネクタで完結する基準応答ケース",
            patterns=[r"^execute/remote_relationships/"],
        ),
        dict(
            feature="native queries",
            level="oos",
            notes="対象外 (将来検討)",
            patterns=[r"native_quer"],
        ),
        dict(
            feature="Apollo Federation / JSON:API",
            level="oos",
            notes="対象外",
            patterns=[r"apollo"],
        ),
        dict(
            feature="plugin hooks (pre/post)",
            level="oos",
            notes="対象外。in-scope の集計はプラグイン無し時の基準応答ケース",
            patterns=[r"^execute/plugins/"],
        ),
        dict(
            feature="Cloudflare Workers (plan/shape 2 フェーズ API)",
            level="own",
            notes="Hasura に無い Mosura 独自機能。pure なコアを Edge で動かすための分割実行 API",
            extra="src/workers / examples/workers",
        ),
    ]),
]


def load_cases():
    text = CASES.read_text(encoding="utf-8")
    return re.findall(r'\[cases\."([^"]+)"\]\ntag = "([^"]+)"', text)


def tally(cases, patterns):
    regexes = [re.compile(p) for p in patterns]
    counts = {"in-scope": 0, "pending": 0, "out-of-scope": 0}
    for cid, tag in cases:
        if any(r.search(cid) for r in regexes):
            counts[tag] += 1
    return counts


def evidence_cell(row, cases):
    parts = []
    if row.get("patterns"):
        c = tally(cases, row["patterns"])
        nums = " / ".join(
            f"{k} {v}" for k, v in c.items() if v > 0
        )
        parts.append(nums if nums else "該当ケースなし")
    if row.get("extra"):
        parts.append(row["extra"])
    return "; ".join(parts) if parts else "—"


def generate():
    cases = load_cases()
    total = {"in-scope": 0, "pending": 0, "out-of-scope": 0}
    for _, tag in cases:
        total[tag] += 1

    lines = [
        "# Hasura V3 互換性マトリクス",
        "",
        "<!-- このファイルは scripts/gen_compat.py が生成する。直接編集せず、"
        "スクリプトの FEATURES を編集して再生成すること (CI で freshness チェックされる) -->",
        "",
        "Hasura GraphQL Engine V3 の機能に対する Mosura の対応状況。",
        "「根拠」列は [fixtures/cases.toml](../fixtures/cases.toml) の台帳集計"
        " (in-scope = 移植元フィクスチャで同一挙動を CI 強制 / pending = 未昇格 /"
        " out-of-scope = 理由付きでスコープ外) と、フィクスチャの無い機能のテスト所在。"
        "行をまたぐケースの重複計上は許容している。",
        "この表に無い機能は未対応と考えること。スコープ判断の経緯は"
        " [implementation-plan.md](implementation-plan.md) を参照。",
        "",
        "## 互換性レベル",
        "",
        "| レベル | 意味 |",
        "|--------|------|",
    ]
    for label, desc in LEVEL_LEGEND:
        lines.append(f"| {label} | {desc} |")
    for area, rows in FEATURES:
        lines += [
            "",
            f"## {area}",
            "",
            "| 機能 | 互換性 | 備考 (差異・制限) | 根拠 | 追跡 |",
            "|------|--------|-------------------|------|------|",
        ]
        for row in rows:
            level = LEVELS[row["level"]]
            issues = ", ".join(row.get("issues", [])) or "—"
            lines.append(
                f"| {row['feature']} | {level} | {row['notes']} |"
                f" {evidence_cell(row, cases)} | {issues} |"
            )
    lines += [
        "",
        "## 台帳サマリ",
        "",
        f"全 {len(cases)} ケース: in-scope {total['in-scope']} /"
        f" pending {total['pending']} / out-of-scope {total['out-of-scope']}"
        " (`python3 scripts/gen_cases.py` の集計と一致)",
        "",
    ]
    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"generated {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    generate()
