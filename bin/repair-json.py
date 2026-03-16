#!/usr/bin/env python3
"""
Repair JSON with unescaped newlines/quotes in strings. Reads file, fixes common issues,
outputs valid JSON to stdout. Use before write-json when source has formatting errors.

Usage:
  python3 bin/repair-json.py broken.json | python3 bin/write-json.py fixed.json
  python3 bin/repair-json.py broken.json  # prints to stdout
"""
import json
import re
import sys
from pathlib import Path


def repair_json_string(content: str) -> str:
    """Replace literal newlines/carriage returns inside JSON string values with \\n/\\r."""
    result = []
    i = 0
    in_string = False
    escape_next = False
    in_single_quote = False  # JSON uses double quotes only, but be safe

    while i < len(content):
        c = content[i]
        if escape_next:
            result.append(c)
            escape_next = False
        elif in_string:
            if c == "\\":
                result.append(c)
                escape_next = True
            elif c == "\n":
                result.append("\\n")
            elif c == "\r":
                result.append("\\r")
            elif c == "\t":
                result.append("\\t")
            elif c == '"':
                result.append(c)
                in_string = False
            else:
                result.append(c)
        else:
            if c == '"':
                result.append(c)
                in_string = True
            else:
                result.append(c)
        i += 1
    return "".join(result)


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 bin/repair-json.py <input_json_file>", file=sys.stderr)
        sys.exit(1)
    path = Path(sys.argv[1])
    if not path.exists():
        print(f"File not found: {path}", file=sys.stderr)
        sys.exit(2)
    content = path.read_text(encoding="utf-8")
    try:
        data = json.loads(content)
        # Already valid, just re-serialize
        print(json.dumps(data, indent=2, ensure_ascii=False))
        return
    except json.JSONDecodeError:
        pass
    repaired = repair_json_string(content)
    try:
        data = json.loads(repaired)
        print(json.dumps(data, indent=2, ensure_ascii=False))
    except json.JSONDecodeError as e:
        print(f"Repair failed: {e}", file=sys.stderr)
        sys.exit(3)


if __name__ == "__main__":
    main()
