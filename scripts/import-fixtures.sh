#!/usr/bin/env bash
# Hasura V3 / ndc-postgres のテスト資産を fixtures/ に取り込む。
# 再実行可能・コミット固定。取り込み後に scripts/gen_cases.py で cases.toml を再生成する。
#
# 使い方:
#   ./scripts/import-fixtures.sh                 # 固定コミットを shallow clone して取り込み
#   HASURA_SRC=... NDC_PG_SRC=... ./scripts/...  # 既存の checkout を使う（コミット一致を検証）
set -euo pipefail

HASURA_COMMIT=22888bebd946b2f3235d6fe0824ee9891a12b6da
NDC_PG_COMMIT=e6c9355ce2572971d9645fa74adb5f98df654a0b

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch() { # $1=url $2=commit $3=dest
  git -C "$3" init -q
  git -C "$3" remote add origin "$1"
  git -C "$3" fetch -q --depth 1 origin "$2"
  git -C "$3" checkout -q FETCH_HEAD
}

if [[ -n "${HASURA_SRC:-}" ]]; then
  [[ "$(git -C "$HASURA_SRC" rev-parse HEAD)" == "$HASURA_COMMIT" ]] || {
    echo "HASURA_SRC is not at pinned commit $HASURA_COMMIT" >&2; exit 1; }
  HASURA="$HASURA_SRC"
else
  HASURA="$WORK/hasura"; mkdir -p "$HASURA"
  fetch https://github.com/hasura/graphql-engine.git "$HASURA_COMMIT" "$HASURA"
fi

if [[ -n "${NDC_PG_SRC:-}" ]]; then
  [[ "$(git -C "$NDC_PG_SRC" rev-parse HEAD)" == "$NDC_PG_COMMIT" ]] || {
    echo "NDC_PG_SRC is not at pinned commit $NDC_PG_COMMIT" >&2; exit 1; }
  NDC_PG="$NDC_PG_SRC"
else
  NDC_PG="$WORK/ndc-postgres"; mkdir -p "$NDC_PG"
  fetch https://github.com/hasura/ndc-postgres.git "$NDC_PG_COMMIT" "$NDC_PG"
fi

FX="$ROOT/fixtures"
rm -rf "$FX/lang-graphql" "$FX/metadata-resolve" "$FX/execute" "$FX/ndc-postgres-translation"
mkdir -p "$FX"

# 1) lang-graphql: パーサ/バリデーションのゴールデン (入力 .graphql + 期待 .txt)
LG="$HASURA/v3/crates/graphql/lang-graphql/tests"
mkdir -p "$FX/lang-graphql"
cp -r "$LG/testdata" "$LG/query_testdata" "$LG/schema_testdata" "$FX/lang-graphql/"
cp "$LG/LICENSE-MIT" "$LG/README.md" "$FX/lang-graphql/"

# 2) metadata-resolve: passing/failing (metadata.json + insta .snap → .expected)
MR="$HASURA/v3/crates/metadata-resolve/tests"
mkdir -p "$FX/metadata-resolve"
cp -r "$MR/passing" "$MR/failing" "$FX/metadata-resolve/"

# 3) engine/tests/execute: E2E (metadata.json + request.gql + session_variables.json + expected.json)
cp -r "$HASURA/v3/crates/engine/tests/execute" "$FX/execute"

# 4) ndc-postgres translation: QueryRequest JSON + 期待 SQL (insta .snap → .expected)
TR="$NDC_PG/crates/query-engine/translation/tests"
mkdir -p "$FX/ndc-postgres-translation"
cp -r "$TR/goldenfiles" "$TR/snapshots" "$FX/ndc-postgres-translation/"
[[ -d "$TR/common" ]] && cp -r "$TR/common" "$FX/ndc-postgres-translation/"

# insta .snap → 素の期待値ファイル (.expected) へ変換
python3 "$ROOT/scripts/convert_snaps.py" "$FX/metadata-resolve" "$FX/ndc-postgres-translation"

# 5) execute 用シード SQL (COPY → INSERT 変換)
python3 "$ROOT/scripts/convert_execute_seed.py" "$HASURA/v3/crates/engine/tests"

# 由来の記録
cat > "$FX/SOURCES.md" <<EOF
# fixtures の由来

自動生成: scripts/import-fixtures.sh（手で編集しない）

| ディレクトリ | 由来 | コミット |
|---|---|---|
| lang-graphql/ | hasura/graphql-engine v3/crates/graphql/lang-graphql/tests | $HASURA_COMMIT |
| metadata-resolve/ | hasura/graphql-engine v3/crates/metadata-resolve/tests | $HASURA_COMMIT |
| execute/ | hasura/graphql-engine v3/crates/engine/tests/execute | $HASURA_COMMIT |
| ndc-postgres-translation/ | hasura/ndc-postgres crates/query-engine/translation/tests | $NDC_PG_COMMIT |

mosura/ 配下のみ Mosura 独自のテスト（移植元に対応フィクスチャが無い機能用）。
EOF

python3 "$ROOT/scripts/gen_cases.py"
echo "done. see fixtures/SOURCES.md and fixtures/cases.toml"
