#!/usr/bin/env python3
"""
parse-am-instrument-results.py — am instrument 텍스트 출력을 파싱하여
all_uitest_results.json 파일을 생성한다.

옵션:
  --shard-dir <dir>          shard_*.log 디렉토리
  --output-dir <dir>         결과 JSON 출력 디렉토리
  --project-path <path>      프로젝트 상대 경로 (메타데이터)
  --selection-filter <json>  선택 필터(JSON 문자열): {"classes":[], "suite":..., "method":...}
"""

import argparse
import glob
import json
import os
import re
import sys


def parse_shard_log(filepath):
    results = []
    current = {}

    try:
        with open(filepath, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError as e:
        print(f"Warning: Cannot read {filepath}: {e}", file=sys.stderr)
        return results

    has_instrumentation_status = False
    for line in lines:
        line = line.strip()
        m = re.match(r"INSTRUMENTATION_STATUS:\s+(\w+)=(.*)", line)
        if m:
            has_instrumentation_status = True
            key, value = m.group(1), m.group(2)
            if key == "class":
                current["className"] = value
            elif key == "test":
                current["testName"] = value
            elif key == "stack":
                current["stackTrace"] = value
            elif key == "stream":
                if "errorMessage" not in current:
                    current["errorMessage"] = value
            continue

        m = re.match(r"INSTRUMENTATION_STATUS_CODE:\s*(-?\d+)", line)
        if m:
            code = int(m.group(1))
            if code != 1 and "className" in current and "testName" in current:
                status = "passed" if code == 0 else "failed"
                results.append({
                    "className": current.get("className", ""),
                    "testName": current.get("testName", ""),
                    "status": status,
                    "errorMessage": current.get("errorMessage", ""),
                    "stackTrace": current.get("stackTrace", ""),
                })
            current = {}
            continue

    if not has_instrumentation_status and not results:
        results = parse_stream_log(filepath)
    return results


def parse_stream_log(filepath):
    results = []
    try:
        with open(filepath, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
    except OSError as e:
        print(f"Warning: Cannot read {filepath}: {e}", file=sys.stderr)
        return results

    error_pattern = re.compile(
        r"Error in ([^\(]+)\(([^\)]+)\):\s*\n(.*?)(?=\nError in |\n[a-zA-Z][\w.]+[A-Z]\w*(?:Test|Suite):|\nINSTRUMENTATION_|\Z)",
        re.DOTALL,
    )
    failed_set = set()
    for m in error_pattern.finditer(content):
        test_name = m.group(1).strip()
        class_name = m.group(2).strip()
        error_body = m.group(3).strip()

        error_message = ""
        stack_trace_lines = []
        for line in error_body.split("\n"):
            stripped = line.strip()
            if stripped.startswith("at ") or stripped.startswith("Caused by:"):
                stack_trace_lines.append(stripped)
            elif stripped.startswith("SKIP["):
                continue
            elif stripped.startswith(("View Hierarchy:", "The complete view hierarchy", "+", "|", "No views in hierarchy")):
                continue
            elif not error_message and stripped:
                error_message = stripped

        key = (class_name, test_name)
        if key not in failed_set:
            failed_set.add(key)
            results.append({
                "className": class_name,
                "testName": test_name,
                "status": "failed",
                "errorMessage": error_message,
                "stackTrace": "\n".join(stack_trace_lines),
            })

    class_header_pattern = re.compile(
        r"^([a-zA-Z][\w.]*\.[A-Z]\w*(?:Test|Suite)):([.\s]*?)$", re.MULTILINE
    )
    for m in class_header_pattern.finditer(content):
        class_name = m.group(1).strip()
        dots_section = m.group(2)
        passed_count = dots_section.count(".")
        for i in range(passed_count):
            results.append({
                "className": class_name,
                "testName": f"passed_test_{i + 1}",
                "status": "passed",
                "errorMessage": "",
                "stackTrace": "",
            })

    return results


def main():
    parser = argparse.ArgumentParser(description="Parse am instrument shard logs")
    parser.add_argument("--shard-dir", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--project-path", default="")
    parser.add_argument("--selection-filter", default="{}")
    args = parser.parse_args()

    shard_files = sorted(glob.glob(os.path.join(args.shard_dir, "shard_*.log")))
    if not shard_files:
        print(f"No shard log files found in {args.shard_dir}", file=sys.stderr)
        # 빈 결과 파일 생성 (다운스트림이 실패 분기 타지 않도록 error 필드 채움)
        os.makedirs(args.output_dir, exist_ok=True)
        with open(os.path.join(args.output_dir, "all_uitest_results.json"), "w", encoding="utf-8") as f:
            json.dump({
                "platform": "android", "projectPath": args.project_path,
                "totalCount": 0, "passedCount": 0, "failedCount": 0,
                "failedTests": [], "selectionFilter": json.loads(args.selection_filter),
                "error": "No shard logs found",
            }, f, indent=2, ensure_ascii=False)
        sys.exit(1)

    all_results = []
    for sf in shard_files:
        results = parse_shard_log(sf)
        print(f"  {os.path.basename(sf)}: {len(results)} results")
        all_results.extend(results)

    total = len(all_results)
    passed = sum(1 for r in all_results if r["status"] == "passed")
    failed = total - passed

    result = {
        "platform": "android",
        "projectPath": args.project_path,
        "totalCount": total,
        "passedCount": passed,
        "failedCount": failed,
        "failedTests": [
            {
                "className": r["className"],
                "testName": r["testName"],
                "errorMessage": r.get("errorMessage", ""),
                "stackTrace": r.get("stackTrace", ""),
                "testFilePath": "",
            }
            for r in all_results if r["status"] != "passed"
        ],
        "selectionFilter": json.loads(args.selection_filter) if args.selection_filter else {},
        "error": "",
    }

    os.makedirs(args.output_dir, exist_ok=True)
    out_path = os.path.join(args.output_dir, "all_uitest_results.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, ensure_ascii=False)
    print(f"Wrote: {out_path} (total={total} pass={passed} fail={failed})")


if __name__ == "__main__":
    main()
