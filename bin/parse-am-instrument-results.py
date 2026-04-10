#!/usr/bin/env python3
"""
parse-am-instrument-results.py — am instrument 텍스트 출력을 파싱하여
all_uitest_results.json 파일을 생성합니다.

사용법:
  python3 bin/parse-am-instrument-results.py [options]

옵션:
  --shard-dir <dir>      shard 로그 디렉토리 (기본: ./test_results)
  --output-dir <dir>     결과 JSON 출력 디렉토리 (기본: .gemini/agents/logs)
  --project-path <path>  프로젝트 상대 경로
"""

import argparse
import glob
import json
import os
import re
import sys


def parse_shard_log(filepath):
    """am instrument 텍스트 출력에서 테스트 결과를 파싱합니다.

    am instrument 출력 형식:
      INSTRUMENTATION_STATUS: class=com.example.MyTest
      INSTRUMENTATION_STATUS: test=testSomething
      INSTRUMENTATION_STATUS: numtests=5
      INSTRUMENTATION_STATUS: current=1
      INSTRUMENTATION_STATUS_CODE: 1      (1=시작)
      ...
      INSTRUMENTATION_STATUS_CODE: 0      (0=pass, -1=error, -2=failure)

    Returns:
        list[dict]: 각 테스트 결과 (className, testName, status, errorMessage, stackTrace)
    """
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

        # INSTRUMENTATION_STATUS: key=value
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
                # stream 필드에 에러 메시지가 포함될 수 있음
                if "errorMessage" not in current:
                    current["errorMessage"] = value
            continue

        # INSTRUMENTATION_STATUS_CODE: <code>
        m = re.match(r"INSTRUMENTATION_STATUS_CODE:\s*(-?\d+)", line)
        if m:
            code = int(m.group(1))
            # code 1 = test started, skip
            # code 0 = pass, -1 = error, -2 = failure
            if code != 1 and "className" in current and "testName" in current:
                status = "passed" if code == 0 else "failed"
                results.append(
                    {
                        "className": current.get("className", ""),
                        "testName": current.get("testName", ""),
                        "status": status,
                        "errorMessage": current.get("errorMessage", ""),
                        "stackTrace": current.get("stackTrace", ""),
                    }
                )
            current = {}
            continue

    # INSTRUMENTATION_STATUS 형식이 없으면 스트림 형식으로 재시도
    if not has_instrumentation_status and not results:
        results = parse_stream_log(filepath)

    return results


def parse_stream_log(filepath):
    """am instrument 스트림(텍스트) 출력에서 테스트 결과를 파싱합니다.

    `-r` 플래그 없이 실행된 am instrument의 출력 형식:
      kr.co.yogiyo.SomeTest:...     (클래스 헤더, 점은 통과한 테스트)
      Error in testName(kr.co.yogiyo.SomeTest):
      java.lang.AssertionError: ...
      ...stack trace...
      INSTRUMENTATION_RESULT: shortMsg=Process crashed.
      INSTRUMENTATION_CODE: 0

    중도 크래시가 발생해도 그때까지 수집된 결과를 반환합니다.

    Returns:
        list[dict]: 각 테스트 결과 (className, testName, status, errorMessage, stackTrace)
    """
    results = []

    try:
        with open(filepath, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
    except OSError as e:
        print(f"Warning: Cannot read {filepath}: {e}", file=sys.stderr)
        return results

    # 1. Error in 블록 파싱 — 실패한 테스트 추출
    # 패턴: Error in TEST_NAME(fully.qualified.ClassName):
    error_pattern = re.compile(
        r"Error in ([^\(]+)\(([^\)]+)\):\s*\n(.*?)(?=\nError in |\n[a-zA-Z][\w.]+[A-Z]\w*(?:Test|Suite):|\nINSTRUMENTATION_|\Z)",
        re.DOTALL,
    )
    failed_set = set()  # (className, testName) -> 중복 방지

    for m in error_pattern.finditer(content):
        test_name = m.group(1).strip()
        class_name = m.group(2).strip()
        error_body = m.group(3).strip()

        # 에러 메시지와 스택 트레이스 분리
        # 스택 트레이스는 View Hierarchy 이후에 나올 수 있으므로 전체를 스캔
        error_lines = error_body.split("\n")
        error_message = ""
        stack_trace_lines = []
        for line in error_lines:
            stripped = line.strip()
            if stripped.startswith("at ") or stripped.startswith("Caused by:"):
                stack_trace_lines.append(stripped)
            elif stripped.startswith("SKIP["):
                continue
            # View Hierarchy, +>, |, 빈 줄 등은 무시
            elif stripped.startswith(("View Hierarchy:", "The complete view hierarchy",
                                      "+", "|", "No views in hierarchy")):
                continue
            elif not error_message and stripped:
                error_message = stripped

        key = (class_name, test_name)
        if key not in failed_set:
            failed_set.add(key)
            results.append(
                {
                    "className": class_name,
                    "testName": test_name,
                    "status": "failed",
                    "errorMessage": error_message,
                    "stackTrace": "\n".join(stack_trace_lines),
                }
            )

    # 2. 클래스 헤더에서 통과한 테스트 수 추정
    # 패턴: kr.co.yogiyo...ClassName:...  (점 하나당 통과 1건)
    class_header_pattern = re.compile(
        r"^([a-zA-Z][\w.]*\.[A-Z]\w*(?:Test|Suite)):([.\s]*?)$", re.MULTILINE
    )

    for m in class_header_pattern.finditer(content):
        class_name = m.group(1).strip()
        dots_section = m.group(2)
        # 점(.) 개수 = 통과한 테스트 수
        passed_count = dots_section.count(".")

        for i in range(passed_count):
            results.append(
                {
                    "className": class_name,
                    "testName": f"passed_test_{i + 1}",
                    "status": "passed",
                    "errorMessage": "",
                    "stackTrace": "",
                }
            )

    # 3. 프로세스 크래시 감지
    crash_match = re.search(
        r"INSTRUMENTATION_RESULT:.*shortMsg=(.*)", content
    )
    if crash_match:
        crash_msg = crash_match.group(1).strip()
        print(f"  [WARN] Process crash detected: {crash_msg}", file=sys.stderr)

    return results


def main():
    parser = argparse.ArgumentParser(
        description="Parse am instrument shard logs into a combined JSON result"
    )
    parser.add_argument(
        "--shard-dir",
        default="./test_results",
        help="Directory containing shard_*.log files",
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

    # 1. 모든 shard 로그 파싱
    shard_files = sorted(glob.glob(os.path.join(args.shard_dir, "shard_*.log")))
    if not shard_files:
        print(
            f"No shard log files found in {args.shard_dir}", file=sys.stderr
        )
        sys.exit(1)

    print(f"Found {len(shard_files)} shard log(s)")

    all_results = []
    for sf in shard_files:
        results = parse_shard_log(sf)
        print(f"  {os.path.basename(sf)}: {len(results)} test results")
        all_results.extend(results)

    total_tests = len(all_results)
    total_passed = sum(1 for r in all_results if r["status"] == "passed")
    total_failed = total_tests - total_passed
    print(f"Total: {total_tests} tests, {total_passed} passed, {total_failed} failed")

    # 2. 전체 결과를 단일 JSON으로 출력
    result = {
        "platform": "android",
        "projectPath": args.project_path or "",
        "totalCount": total_tests,
        "passedCount": total_passed,
        "failedCount": total_failed,
        "failedTests": [
            {
                "className": r["className"],
                "testName": r["testName"],
                "errorMessage": r.get("errorMessage", ""),
                "stackTrace": r.get("stackTrace", ""),
                "testFilePath": "",
            }
            for r in all_results
            if r["status"] != "passed"
        ],
        "error": "",
    }

    os.makedirs(args.output_dir, exist_ok=True)
    out_path = os.path.join(args.output_dir, "all_uitest_results.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, ensure_ascii=False)
    print(f"Wrote combined results to: {out_path}")


if __name__ == "__main__":
    main()
