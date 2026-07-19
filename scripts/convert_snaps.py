#!/usr/bin/env python3
"""insta 形式の .snap を素の期待値ファイル (.expected) に変換する。

.snap は `---` で囲まれた YAML ヘッダ (source/expression/input_file) の後に
期待値本体が続く。ヘッダを剥がして .expected として保存し、.snap は削除する。
"""
import sys
from pathlib import Path


def convert(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    lines = text.split("\n")
    if lines[0] != "---":
        raise ValueError(f"not an insta snapshot (missing header): {path}")
    try:
        end = lines.index("---", 1)
    except ValueError:
        raise ValueError(f"unterminated insta header: {path}") from None
    body = "\n".join(lines[end + 1 :])
    path.with_suffix(".expected").write_text(body, encoding="utf-8")
    path.unlink()


def main() -> None:
    total = 0
    for root in sys.argv[1:]:
        for snap in sorted(Path(root).rglob("*.snap")):
            convert(snap)
            total += 1
    print(f"converted {total} .snap files")


if __name__ == "__main__":
    main()
