#!/usr/bin/env python3
"""
parse-xcresult.py — xcresult 번들을 파싱하여 all_uitest_results.json 생성

옵션:
  --xcresult <path>          xcresult 번들 경로 (필수)
  --output-dir <dir>         출력 디렉토리
  --project-path <path>      프로젝트 상대 경로
  --selection-filter <json>  선택 필터 JSON 문자열
"""

import argparse
import json
import os
import subprocess
import sys


def parse_xcresult(result_path):
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
                # failure details 추출
                failure_msg = result
                stack = ""
                for c in node.get("children", []):
                    if c.get("nodeType") == "Failure Message":
                        failure_msg = c.get("name", result)
                    elif c.get("nodeType") == "Source Code Reference":
                        stack = c.get("name", "")
                failed_tests.append({
                    "className": class_name,
                    "testName": name,
                    "errorMessage": failure_msg,
                    "stackTrace": stack,
                    "testFilePath": "",
                })
        elif "children" in node:
            child_class = name if node_type == "Test Suite" else class_name
            for child in node["children"]:
                walk_nodes(child, child_class)

    for node in data.get("testNodes", []):
        walk_nodes(node)

    return total, passed, failed_tests


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--xcresult", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--project-path", default="")
    parser.add_argument("--selection-filter", default="{}")
    args = parser.parse_args()

    if not os.path.isdir(args.xcresult):
        print(f"Error: xcresult not found: {args.xcresult}", file=sys.stderr)
        sys.exit(1)

    try:
        total, passed, failed_tests = parse_xcresult(args.xcresult)
        err = ""
    except Exception as e:
        print(f"Error parsing xcresult: {e}", file=sys.stderr)
        total, passed, failed_tests, err = 0, 0, [], str(e)

    result = {
        "platform": "ios",
        "projectPath": args.project_path,
        "totalCount": total,
        "passedCount": passed,
        "failedCount": len(failed_tests),
        "failedTests": failed_tests,
        "selectionFilter": json.loads(args.selection_filter) if args.selection_filter else {},
        "error": err,
    }

    os.makedirs(args.output_dir, exist_ok=True)
    out_path = os.path.join(args.output_dir, "all_uitest_results.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, ensure_ascii=False)
    print(f"Wrote: {out_path} (total={total} pass={passed} fail={len(failed_tests)})")


if __name__ == "__main__":
    main()
