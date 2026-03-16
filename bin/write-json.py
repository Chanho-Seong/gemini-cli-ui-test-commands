#!/usr/bin/env python3
"""
Write JSON to file with proper escaping. Reads JSON from stdin, parses it,
and writes with json.dump to ensure valid output (no unescaped newlines, quotes, etc.).
Use when agents need to write uitest_results.json or device_verification.json.

Usage:
  echo '{"key":"value"}' | python3 bin/write-json.py output.json
  python3 -c "import json; print(json.dumps(obj))" | python3 bin/write-json.py output.json
"""
import json
import sys
from pathlib import Path


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 bin/write-json.py <output_path>", file=sys.stderr)
        sys.exit(1)
    out_path = Path(sys.argv[1])
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        print(f"Invalid JSON input: {e}", file=sys.stderr)
        sys.exit(2)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    print(str(out_path.resolve()))


if __name__ == "__main__":
    main()
