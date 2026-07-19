#!/usr/bin/env python3
"""V3 engine テストのシード SQL (COPY 形式の pg_dump) を、ワイヤプロトコルの
batch_execute で実行できる INSERT 形式へ変換する。OWNER TO は除去する。

使い方: python3 scripts/convert_execute_seed.py <v3>/crates/engine/tests
出力: fixtures/execute-seed/{db_definition,chinook-postgres}.sql
"""
import re, sys
from pathlib import Path

def convert(sql_text):
    out_lines = []
    lines = sql_text.split('\n')
    i = 0
    while i < len(lines):
        line = lines[i]
        if re.match(r'^\s*ALTER TABLE .* OWNER TO ', line):
            i += 1
            continue
        m = re.match(r'^COPY\s+(\S+)\s*\(([^)]*)\)\s+FROM\s+stdin;\s*$', line, re.I)
        if m:
            table, cols = m.group(1), m.group(2)
            i += 1
            rows = []
            while i < len(lines) and lines[i] != '\\.':
                raw = lines[i]
                if raw.strip() == '':
                    i += 1
                    continue
                vals = raw.split('\t')
                svals = []
                for v in vals:
                    if v == '\\N':
                        svals.append('NULL')
                    else:
                        v = v.replace('\\\\', '\\')
                        svals.append("'" + v.replace("'", "''") + "'")
                rows.append('(' + ', '.join(svals) + ')')
                i += 1
            i += 1  # skip \.
            for k in range(0, len(rows), 100):
                chunk = rows[k:k+100]
                out_lines.append(f'INSERT INTO {table} ({cols}) VALUES\n' + ',\n'.join(chunk) + ';')
            continue
        out_lines.append(line)
        i += 1
    return '\n'.join(out_lines)

base = Path(sys.argv[1])
outdir = Path('fixtures/execute-seed')
outdir.mkdir(exist_ok=True)
for name in ['db_definition.sql', 'chinook-postgres.sql']:
    converted = convert((base / name).read_text())
    (outdir / name).write_text(converted)
    print(name, '->', len(converted), 'bytes')
