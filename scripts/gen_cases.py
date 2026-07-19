#!/usr/bin/env python3
"""fixtures/ を走査して fixtures/cases.toml（テストケース台帳）を再生成する。

- 全ケースを列挙し、in-scope / pending / out-of-scope(reason) のタグを付ける
- 既存の cases.toml のタグは維持される（手動でのタグ変更は再実行で消えない）
- 新規ケースはヒューリスティックで初期タグを付ける
- タグの意味は docs/implementation-plan.md §1 を参照
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
FX = ROOT / "fixtures"
CASES = FX / "cases.toml"

# パスにこのキーワードを含むケースは MVP 対象外（理由つき）
OUT_OF_SCOPE = [
    ("aggregate", "aggregates は MVP 対象外"),
    ("command", "Command 機構は採用しない (V2 風 CRUD を採用)"),
    ("procedure", "Command 機構は採用しない (V2 風 CRUD を採用)"),
    ("function", "Command 機構は採用しない (V2 風 CRUD を採用)"),
    ("apollo", "Apollo Federation は対象外"),
    ("jsonapi", "JSON:API は対象外"),
    ("remote_relationship", "remote relationships (複数コネクタ) は対象外"),
    ("remote_predicates", "remote relationships (複数コネクタ) は対象外"),
    ("subscription", "subscription は対象外"),
    ("plugin", "plugin hook は対象外"),
    ("native_quer", "native queries は対象外 (将来検討)"),
    ("usage_analytics", "usage analytics は対象外"),
    ("query_usage", "usage analytics は対象外"),
]


def classify(case_id):
    """(tag, milestone, reason) を返す"""
    lower = case_id.lower()
    for kw, reason in OUT_OF_SCOPE:
        if kw in lower:
            return "out-of-scope", "", reason
    if case_id.startswith("lang-graphql/"):
        return "pending", "m1", ""
    if case_id.startswith("metadata-resolve/"):
        return "pending", "m2", ""
    if case_id.startswith("ndc-postgres-translation/goldenfiles/mutations"):
        return "pending", "m6", ""
    if case_id.startswith("ndc-postgres-translation/"):
        return "pending", "m3", ""
    if case_id.startswith("execute/"):
        if "introspection" in lower:
            return "pending", "m2", ""
        if "permission" in lower or "session" in lower or "role" in lower:
            return "pending", "m5", ""
        return "pending", "m4", ""
    return "pending", "", ""


def enumerate_cases():
    cases = []

    # lang-graphql: 入力 .graphql が 1 ケース
    for f in sorted((FX / "lang-graphql").rglob("*.graphql")):
        cases.append(str(f.relative_to(FX).with_suffix("")))

    # metadata-resolve: metadata.json を含むディレクトリが 1 ケース
    for f in sorted((FX / "metadata-resolve").rglob("metadata.json")):
        cases.append(str(f.parent.relative_to(FX)))

    # execute: request.gql を含むディレクトリが 1 ケース
    for f in sorted((FX / "execute").rglob("request.gql")):
        cases.append(str(f.parent.relative_to(FX)))

    # ndc-postgres-translation: request.json を含むディレクトリが 1 ケース
    for f in sorted((FX / "ndc-postgres-translation" / "goldenfiles").rglob("request.json")):
        cases.append(str(f.parent.relative_to(FX)))

    # mosura 独自テスト (移植元に対応が無い機能): ディレクトリ単位
    mosura = FX / "mosura"
    if mosura.is_dir():
        for f in sorted(mosura.rglob("case.toml")):
            cases.append(str(f.parent.relative_to(FX)))

    return cases


def load_existing():
    """既存 cases.toml から {case_id: {tag, milestone, reason}} を読む（簡易パーサ）"""
    if not CASES.exists():
        return {}
    entries = {}
    current = None
    for line in CASES.read_text(encoding="utf-8").splitlines():
        m = re.match(r'^\[cases\."(.+)"\]$', line.strip())
        if m:
            current = {}
            entries[m.group(1)] = current
            continue
        if current is not None:
            kv = re.match(r'^(\w+)\s*=\s*"(.*)"$', line.strip())
            if kv:
                current[kv.group(1)] = kv.group(2)
    return entries


def main():
    existing = load_existing()
    cases = enumerate_cases()
    counts = {"in-scope": 0, "pending": 0, "out-of-scope": 0}
    lines = [
        "# テストケース台帳 (scripts/gen_cases.py が生成。tag/milestone/reason の手動編集は再生成後も維持される)",
        "# tag: in-scope (CI で実行・グリーン維持) / pending (未着手の M に属する) / out-of-scope (MVP 対象外、削除しない)",
        "",
    ]
    for case_id in cases:
        prev = existing.get(case_id)
        if prev and "tag" in prev:
            tag = prev["tag"]
            milestone = prev.get("milestone", "")
            reason = prev.get("reason", "")
        else:
            tag, milestone, reason = classify(case_id)
        counts[tag] = counts.get(tag, 0) + 1
        lines.append(f'[cases."{case_id}"]')
        lines.append(f'tag = "{tag}"')
        if milestone:
            lines.append(f'milestone = "{milestone}"')
        if reason:
            lines.append(f'reason = "{reason}"')
        lines.append("")
    CASES.write_text("\n".join(lines), encoding="utf-8")
    total = len(cases)
    print(f"cases: {total} (in-scope: {counts.get('in-scope', 0)}, pending: {counts.get('pending', 0)}, out-of-scope: {counts.get('out-of-scope', 0)})")


if __name__ == "__main__":
    main()
