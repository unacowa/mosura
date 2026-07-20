#!/usr/bin/env python3
"""docs/compatibility.md (Hasura V3 互換性マトリクス) を生成する。

- 行 (機能・レベル・対応/非対応の境界) はこのファイルの FEATURES を編集して再生成する
- 各行の「根拠」列は fixtures/cases.toml のタグ集計から自動算出される
- CI が再生成して diff が無いことをチェックする (cases.toml と同じ freshness 運用)

互換性レベルの判定方針:
- full    (✅ 互換)     : 移植元のフィクスチャ/ゴールデンで同一挙動を CI 強制している
- partial (🟡 部分互換) : サブセットを同一挙動で対応。境界は「対応 / 非対応」列に明記
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
    ("🟡 部分互換", "サブセットを同一挙動で対応。境界は「対応」「非対応 / 差異」列に明記"),
    ("🔄 独自実装", "意図的に Hasura と異なる設計を選択 (経緯は implementation-plan.md)"),
    ("❌ 未対応", "将来実装する想定 (Issue または台帳の pending で追跡)"),
    ("🚫 対象外", "スコープ外と判断 (理由は cases.toml の out-of-scope reason)"),
]

# feature: 機能名 / level: LEVELS のキー
# supported: 互換に動く範囲 (何が Hasura と同じに使えるか)
# unsupported: 非対応・挙動が異なる範囲 (何が使えない / 違うか)
# patterns: cases.toml のケース ID にマッチする正規表現 (集計対象。行間の重複は許容)
# extra: フィクスチャ以外の根拠 (テストファイル等) / issues: 追跡 Issue
FEATURES = [
    ("GraphQL API (クエリ)", [
        dict(
            feature="GraphQL パース/バリデーション",
            level="full",
            supported="クエリ・SDL の構文パースと AST 構築。Rust `{:#?}` 互換のデバッグ出力までバイト一致",
            unsupported="SDL の directive 定義・type extension・supergraph 構文 (out-of-scope 11 件)。"
            "`@include` / `@skip` は実行時に評価されない",
            patterns=[r"^lang-graphql/"],
            issues=['#37'],
        ),
        dict(
            feature="introspection",
            level="partial",
            supported="`__schema` / `__type` / `__typename`。型・フィールド・入力型・enum を"
            "ロール別可視性込みで返す",
            unsupported="V3 ゴールデンとの応答バイト一致は未検証 (pending 4)。"
            "GraphqlConfig による introspection カスタマイズ",
            patterns=[r"introspection"],
        ),
        dict(
            feature="モデル select",
            level="partial",
            supported="`where` (スカラー比較 `_eq` `_neq` `_gt` `_gte` `_lt` `_lte` `_in` `_like` "
            "`_is_null` と `_and` / `_or` / `_not`)、`order_by`、`limit` / `offset`、"
            "エイリアス・複数ルートフィールド",
            unsupported="テキスト検索演算子は `_like` のみ (`_ilike` `_regex` `_similar` 等は未実装)。"
            "order_by 方向は V2 系 6 値 enum (`asc` … `desc_nulls_last`) — V3 の `Asc`/`Desc` 2 値"
            "とは記法非互換で、null 配置も固定でない。1 つの order_by オブジェクトに複数キーを"
            "書いてもエラーにしない (V3 はエラー)。ネスト/composite/配列型カラム、"
            "model arguments、native query 前提のモデル",
            patterns=[r"^execute/models/", r"^ndc-postgres-translation/goldenfiles/select_"],
            issues=['#33', '#34', '#36'],
        ),
        dict(
            feature="by_pk 単一取得",
            level="partial",
            supported="`<model>_by_pk` (複合主キー可)。ロール可視性・行フィルタ適用",
            unsupported="V3 の selectUniques 相当 (主キー以外の unique キー、カスタムフィールド名)",
            extra="src/e2e/e2e_test.mbt",
        ),
        dict(
            feature="リレーション (入れ子選択)",
            level="partial",
            supported="object / array リレーションの入れ子選択。array 側は `where` / `order_by` / "
            "`limit` / `offset` 引数付き。対象モデルのロール可視性と行フィルタを適用",
            unsupported="複数コネクタ跨ぎ (remote relationships)、リレーション先の aggregates",
            patterns=[r"^execute/relationships/"],
        ),
        dict(
            feature="where のリレーション跨ぎ filter",
            level="todo",
            supported="なし (GraphQL からは書けない)",
            unsupported="bool_exp にリレーションフィールドが生成されない。"
            "NDC/SQL 層の exists 変換は実装済みで、bool_exp 生成と IR 配線のみが残作業",
            issues=['#32'],
        ),
        dict(
            feature="order_by のリレーション跨ぎ",
            level="partial",
            supported="object リレーション経由のカラムソート (複数カラム・複数経路、"
            "同一経路の JOIN 共有、経路上の predicate)",
            unsupported="array リレーション越しのカラムソート (要 aggregate — 明示的に拒否)、"
            "field_path によるネストフィールドソート (拒否)、relationship count でのソート (拒否)",
            patterns=[r"^ndc-postgres-translation/goldenfiles/sorting_"],
        ),
        dict(
            feature="GraphQL 変数",
            level="partial",
            supported="クエリ変数の展開と型検査 (自前 E2E で検証)",
            unsupported="V3 execute ゴールデン 6 件は未昇格 (V3 との応答一致は未検証)",
            patterns=[r"^execute/variables/"],
        ),
        dict(
            feature="集約 (aggregates)",
            level="oos",
            supported="なし",
            unsupported="集約クエリ・集約フィールド・集約 predicate のすべて (MVP 対象外)",
            patterns=[r"^execute/aggregates/", r"^ndc-postgres-translation/goldenfiles/aggregate"],
        ),
        dict(
            feature="Relay",
            level="todo",
            supported="なし",
            unsupported="node インターフェース・global ID (台帳では pending)",
            patterns=[r"^execute/relay/"],
        ),
        dict(
            feature="subscriptions",
            level="oos",
            supported="なし",
            unsupported="すべて。メタデータの allowSubscriptions は読み込むが機能しない",
        ),
    ]),
    ("ミューテーション", [
        dict(
            feature="自動 CRUD (V2 風)",
            level="own",
            supported="`insert_<model>` (複数行、省略カラムは DEFAULT)、"
            "`update_<model>_by_pk` (`_set`)、`delete_<model>_by_pk`、"
            "`affected_rows` / `returning`",
            unsupported="V3 の Command ベース mutation とはスキーマ非互換 (意図的)。"
            "V2 と比べても `on_conflict` (upsert)、`_inc` 等の更新演算子、"
            "`update_<model>` / `delete_<model>` (where 一括)、`insert_<model>_one` は無い。"
            "SQL 形状も独自 (CTE + json_agg)。複数行 INSERT のカラム集合が先頭行由来 (#20)",
            patterns=[r"^mosura/mutations/"],
            issues=["#20"],
        ),
        dict(
            feature="Command 機構 (commands / functions / procedures)",
            level="oos",
            supported="なし",
            unsupported="すべて (V2 風 CRUD を選択。経緯は implementation-plan.md §4)",
            patterns=[r"^execute/commands/"],
        ),
        dict(
            feature="post-write 権限 CHECK / トランザクション分離",
            level="todo",
            supported="なし",
            unsupported="upstream mutation/v2 の RETURNING `%check__constraint` + bool_and と "
            "`BEGIN ISOLATION LEVEL … COMMIT` に相当する機能",
            patterns=[r"^ndc-postgres-translation/goldenfiles/mutations/"],
            issues=["#18"],
        ),
    ]),
    ("権限・認証", [
        dict(
            feature="select 行フィルタ (ModelPermissions)",
            level="partial",
            supported="`fieldComparison` (field / operator / value) と `and` / `or` / `not`。"
            "値は `sessionVariable` / `literal`。WHERE への AND 合成はルート・入れ子とも適用",
            unsupported="リレーションを跨ぐ filter 条件、ネストフィールド条件、"
            "V3 の rules-based permissions (v3_compat では skip される)",
            patterns=[r"^execute/session_variables/"],
            extra="src/e2e/permissions_test.mbt",
            issues=['#38'],
        ),
        dict(
            feature="カラム可視性 (TypePermissions)",
            level="partial",
            supported="allowedFields によるロール別の出力フィールド可視性 "
            "(不可視フィールドの参照は validation エラー)",
            unsupported="入力型はここでは制御しない (ModelPermissions の columns / presets 側)。"
            "V3 の rules-based permissions は skip される",
            extra="src/schema (Namespaced) / src/e2e/permissions_test.mbt",
        ),
        dict(
            feature="ミューテーション権限",
            level="own",
            supported="insert / update の columns 制限と presets (sessionVariable / literal)、"
            "update / delete の行フィルタ、ロール別のルートフィールド・入力フィールド可視性、"
            "権限拒否・セッション変数不足の専用エラー (fail-closed)",
            unsupported="post-write CHECK (#18)。V3 の command permissions / ArgumentPresets "
            "形式のメタデータ (対象が V2 風 CRUD なので構造が異なる)",
            extra="src/e2e/mutation_permissions_test.mbt",
            issues=["#18"],
        ),
        dict(
            feature="認証: adminSecret (開発モード)",
            level="partial",
            supported="`x-hasura-admin-secret` 一致で `x-hasura-role` / `x-hasura-*` を信頼。"
            "AuthConfig 省略時は全リクエスト admin (V3 の noAuth 相当)。"
            "AuthConfig があるのに認証方式が無い場合は fail-closed で拒否",
            unsupported="webhook 認証モード",
            extra="src/session/jwt_test.mbt",
        ),
        dict(
            feature="認証: JWT",
            level="partial",
            supported="HS256 署名検証 (定数時間比較)、V2 (`https://hasura.io/jwt/claims`) / "
            "V3 (`claims.jwt.hasura.io`) 両 claims 名前空間、default-role / allowed-roles、"
            "`x-hasura-role` ヘッダによるロール切替、`x-hasura-*` claim のセッション変数化、"
            "exp / nbf 検査",
            unsupported="RS256 / ES256 等の非対称鍵、JWKS URL、audience / issuer 検査、"
            "文字列化 (stringified JSON) claims、claims_map / claims 位置のカスタマイズ、"
            "webhook モード",
            extra="src/session/jwt_test.mbt",
            issues=['#41'],
        ),
    ]),
    ("メタデータ", [
        dict(
            feature="Mosura ネイティブ YAML",
            level="own",
            supported="kind: DataConnectorLink / ObjectType / Model / Relationship / "
            "ModelPermissions / TypePermissions / AuthConfig (OpenDD の語彙を踏襲)",
            unsupported="上記以外の OpenDD kind。DDN ビルドサービス・supergraph 合成は持たない "
            "(エンジンが YAML を直接ロード・検証)",
            extra="src/metadata/loader_test.mbt",
        ),
        dict(
            feature="V3 metadata.json (subgraphs 形式) の互換ロード",
            level="partial",
            supported="ObjectType / Model / Relationship / ModelPermissions / TypePermissions / "
            "DataConnectorLink を変換。filter 解決は新形式 BooleanExpressionType (object operand の "
            "comparableFields) と旧 ObjectBooleanExpressionType の両対応で、解決できない "
            "filterExpressionType は fail-closed でロードエラー (サイレントにフィルタを落とさない)。"
            "未定義 connector のスタブ生成",
            unsupported="BooleanExpressionType の comparableRelationships (リレーション述語 — #32/#38)。"
            "Command 系 Relationship、rules-based permissions、Model v2 / OrderByExpression / "
            "GraphqlConfig 等の kind は skip。resolved スナップショット完全一致 (pending 211)",
            patterns=[r"^metadata-resolve/"],
            issues=['#35', '#40'],
        ),
    ]),
    ("データコネクタ (NDC) / 実行系", [
        dict(
            feature="NDC 境界 (QueryRequest)",
            level="partial",
            supported="QueryRequest サブセット (fields / predicate / order_by / limit / offset / "
            "variables / collection_relationships) を in-process trait 越しに使用",
            unsupported="NDC HTTP プロトコル (独立プロセスのコネクタ)、capabilities ネゴシエーション。"
            "MutationRequest は使わない (ミューテーションは NDC を通さず SQL を直接生成)",
            extra="docs/architecture.md",
        ),
        dict(
            feature="ndc-postgres SQL 生成",
            level="partial",
            supported="select / filter / sort / relationship / variables 系の SQL を移植ゴールデンと"
            "バイト一致で生成 (エイリアス採番・クオート含む)",
            unsupported="aggregates、native queries、ネスト/composite/配列型、"
            "mutation v2 の SQL 形状",
            patterns=[r"^ndc-postgres-translation/goldenfiles/"],
        ),
        dict(
            feature="PostgreSQL 実行",
            level="partial",
            supported="PG ワイヤプロトコルの native 実装で V3 execute フィクスチャの応答一致を "
            "PG16 に対して E2E 検証",
            unsupported="pending 112 件は未昇格 (V3 記法・上記機能ギャップに依存)。"
            "エラー応答は internal error に詳細メッセージを含む (V3 は \"internal error\" のみ)",
            patterns=[r"^execute/"],
            issues=['#39'],
        ),
        dict(
            feature="remote relationships (複数コネクタ)",
            level="oos",
            supported="なし",
            unsupported="すべて (in-scope 1 件は単一コネクタで完結する基準応答ケース)",
            patterns=[r"^execute/remote_relationships/"],
        ),
        dict(
            feature="native queries",
            level="oos",
            supported="なし",
            unsupported="すべて (将来検討)",
            patterns=[r"native_quer"],
        ),
        dict(
            feature="Apollo Federation / JSON:API",
            level="oos",
            supported="なし",
            unsupported="すべて",
            patterns=[r"apollo"],
        ),
        dict(
            feature="plugin hooks (pre/post)",
            level="oos",
            supported="なし",
            unsupported="すべて (in-scope 3 件はプラグイン無し時の基準応答ケース)",
            patterns=[r"^execute/plugins/"],
        ),
        dict(
            feature="Cloudflare Workers (plan/shape 2 フェーズ API)",
            level="own",
            supported="pure なコアを Edge で動かすための分割実行 API (Mosura 独自)",
            unsupported="Hasura に対応する機能は無い",
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
        nums = " / ".join(f"{k} {v}" for k, v in c.items() if v > 0)
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
        "Hasura GraphQL Engine V3 の機能に対する Mosura の対応状況。"
        "「対応」列が互換に使える範囲、「非対応 / 差異」列が使えない・挙動が異なる範囲で、"
        "両列の間が互換性の境界。",
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
            "| 機能 | 互換性 | 対応 | 非対応 / 差異 | 根拠 | 追跡 |",
            "|------|--------|------|---------------|------|------|",
        ]
        for row in rows:
            level = LEVELS[row["level"]]
            issues = ", ".join(row.get("issues", [])) or "—"
            lines.append(
                f"| {row['feature']} | {level} | {row['supported']} |"
                f" {row['unsupported']} | {evidence_cell(row, cases)} | {issues} |"
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
