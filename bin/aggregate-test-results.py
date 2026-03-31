#!/usr/bin/env python3
"""
aggregate-test-results.py — 여러 uitest_results.json 파일을 하나로 병합합니다.

사용법:
  python3 bin/aggregate-test-results.py [options]

옵션:
  -d, --dir <dir>       결과 파일이 있는 디렉토리 (기본: .gemini/agents/logs)
  -o, --output <path>   출력 파일 경로 (기본: .gemini/agents/logs/aggregated_uitest_results.json)
  -p, --pattern <glob>  파일 패턴 (기본: *_uitest_results.json)
  --summary             요약만 출력 (파일 생성 안 함)
"""

import argparse
import glob
import json
import os
import sys


def find_result_files(directory, pattern):
    """지정 디렉토리에서 uitest_results.json 파일들을 찾습니다."""
    search_path = os.path.join(directory, pattern)
    files = sorted(glob.glob(search_path))
    # aggregated 파일 자체는 제외
    files = [f for f in files if "aggregated_" not in os.path.basename(f)]
    return files


def merge_results(files):
    """여러 결과 파일을 하나로 병합합니다."""
    merged = {
        "platform": "",
        "projectPath": "",
        "totalCount": 0,
        "passedCount": 0,
        "failedCount": 0,
        "failedTests": [],
        "sourceFiles": [],
    }

    seen_failures = set()  # (className, testName) 중복 방지

    for filepath in files:
        try:
            with open(filepath, "r", encoding="utf-8") as f:
                data = json.load(f)
        except (json.JSONDecodeError, OSError) as e:
            print(f"Warning: Skipping {filepath}: {e}", file=sys.stderr)
            continue

        # 첫 번째 파일에서 platform, projectPath 가져오기
        if not merged["platform"] and data.get("platform"):
            merged["platform"] = data["platform"]
        if not merged["projectPath"] and data.get("projectPath"):
            merged["projectPath"] = data["projectPath"]

        merged["totalCount"] += data.get("totalCount", 0)
        merged["passedCount"] += data.get("passedCount", 0)
        merged["failedCount"] += data.get("failedCount", 0)
        merged["sourceFiles"].append(os.path.basename(filepath))

        for test in data.get("failedTests", []):
            key = (test.get("className", ""), test.get("testName", ""))
            if key not in seen_failures:
                seen_failures.add(key)
                merged["failedTests"].append(test)

    # failedCount를 실제 실패 수로 보정 (중복 제거 후)
    merged["failedCount"] = len(merged["failedTests"])

    return merged


def print_summary(merged):
    """병합 결과 요약을 출력합니다."""
    total = merged["totalCount"]
    passed = merged["passedCount"]
    failed = merged["failedCount"]
    sources = len(merged["sourceFiles"])

    print(f"=== UITest Results Summary ===")
    print(f"Source files: {sources}")
    print(f"Platform: {merged['platform'] or 'unknown'}")
    print(f"Total: {total}, Passed: {passed}, Failed: {failed}")

    if merged["failedTests"]:
        # Group by className
        by_class = {}
        for t in merged["failedTests"]:
            cls = t.get("className", "unknown")
            by_class.setdefault(cls, []).append(t)

        print(f"\nFailed classes: {len(by_class)}")
        print(f"{'Class':<55} {'Tests':<6}")
        print("-" * 61)
        for cls, tests in sorted(by_class.items()):
            short_cls = cls.split(".")[-1] if "." in cls else cls
            print(f"{short_cls:<55} {len(tests):<6}")
            for t in tests:
                print(f"  - {t.get('testName', '?')}")
    else:
        print("\nNo failures found.")


def main():
    parser = argparse.ArgumentParser(description="Aggregate UITest result files")
    parser.add_argument(
        "-d", "--dir",
        default=".gemini/agents/logs",
        help="Directory containing result files",
    )
    parser.add_argument(
        "-o", "--output",
        default=".gemini/agents/logs/aggregated_uitest_results.json",
        help="Output file path",
    )
    parser.add_argument(
        "-p", "--pattern",
        default="*_uitest_results.json",
        help="Glob pattern for result files",
    )
    parser.add_argument(
        "--summary",
        action="store_true",
        help="Print summary only, do not write output file",
    )
    args = parser.parse_args()

    files = find_result_files(args.dir, args.pattern)
    if not files:
        print(f"No result files found in {args.dir} matching {args.pattern}", file=sys.stderr)
        sys.exit(1)

    print(f"Found {len(files)} result file(s)")
    merged = merge_results(files)
    print_summary(merged)

    if not args.summary:
        os.makedirs(os.path.dirname(args.output), exist_ok=True)
        with open(args.output, "w", encoding="utf-8") as f:
            json.dump(merged, f, indent=2, ensure_ascii=False)
        print(f"\nAggregated results written to: {args.output}")


if __name__ == "__main__":
    main()
