#!/usr/bin/env python3
"""
parse-xcresult.py — xcresult 번들을 파싱하여
all_uitest_results.json 파일을 생성합니다.

사용법:
  python3 bin/parse-xcresult.py [options]

옵션:
  --xcresult <path>      xcresult 번들 경로
  --output-dir <dir>     결과 JSON 출력 디렉토리 (기본: .gemini/agents/logs)
  --project-path <path>  프로젝트 상대 경로
"""

import argparse
import json
import os
import subprocess
import sys


def parse_xcresult(result_path):
    """xcresult 번들에서 테스트 결과를 파싱합니다.

    xcrun xcresulttool get test-results tests --path <path> 명령의 출력을 파싱합니다.

    Returns:
        tuple: (total, passed, failed_tests)
    """
    raw = subprocess.check_output(
        [
            "xcrun", "xcresulttool", "get", "test-results", "tests",
            "--path", result_path, "--compact",
        ],
        text=True,
    )
    data = json.loads(raw)

    failed_tests = []
    total = 0
    passed = 0

    def walk_nodes(node, class_name=""):
        nonlocal total, passed
        node_type = node.get("nodeType", "")
        name = node.get("name", class_name)

        if node_type == "Test Case":
            total += 1
            result = node.get("result", "")
            if result == "Passed":
                passed += 1
            else:
                failed_tests.append(
                    {
                        "className": class_name,
                        "testName": name,
                        "errorMessage": result,
                        "stackTrace": "",
                        "testFilePath": "",
                    }
                )
        elif "children" in node:
            child_class = name if node_type == "Test Suite" else class_name
            for child in node["children"]:
                walk_nodes(child, child_class)

    for node in data.get("testNodes", []):
        walk_nodes(node)

    return total, passed, failed_tests


def main():
    parser = argparse.ArgumentParser(
        description="Parse xcresult bundle into a combined JSON result"
    )
    parser.add_argument(
        "--xcresult", required=True, help="Path to .xcresult bundle"
    )
    parser.add_argument(
        "--output-dir",
        default=".gemini/agents/logs",
        help="Directory to write the result JSON file",
    )
    parser.add_argument(
        "--project-path", default="", help="Relative project path for result metadata"
    )
    args = parser.parse_args()

    if not os.path.isdir(args.xcresult):
        print(f"Error: xcresult not found: {args.xcresult}", file=sys.stderr)
        sys.exit(1)

    print(f"Parsing xcresult: {args.xcresult}")

    try:
        total, passed, failed_tests = parse_xcresult(args.xcresult)
        print(f"Parsed {total} tests, {len(failed_tests)} failures")

        result = {
            "platform": "ios",
            "projectPath": args.project_path or "",
            "totalCount": total,
            "passedCount": passed,
            "failedCount": len(failed_tests),
            "failedTests": failed_tests,
            "error": "",
        }
    except Exception as e:
        print(f"Error parsing xcresult: {e}", file=sys.stderr)
        result = {
            "platform": "ios",
            "projectPath": args.project_path or "",
            "totalCount": 0,
            "passedCount": 0,
            "failedCount": 0,
            "failedTests": [],
            "error": str(e),
        }

    os.makedirs(args.output_dir, exist_ok=True)
    out_path = os.path.join(args.output_dir, "all_uitest_results.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, ensure_ascii=False)
    print(f"Wrote results to: {out_path}")


if __name__ == "__main__":
    main()
