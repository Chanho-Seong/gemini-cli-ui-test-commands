#!/usr/bin/env python3
"""
parse-am-instrument-results.py — am instrument 텍스트 출력을 파싱하여
per-task uitest_results.json 파일을 생성합니다.

사용법:
  python3 bin/parse-am-instrument-results.py [options]

옵션:
  --shard-dir <dir>      shard 로그 디렉토리 (기본: ./test_results)
  --tasks-dir <dir>      태스크 JSON 디렉토리 (기본: .gemini/agents/tasks)
  --output-dir <dir>     결과 JSON 출력 디렉토리 (기본: .gemini/agents/logs)
  --project-path <path>  프로젝트 상대 경로
  --module <name>        모듈명 (기본: yogiyo)
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

    for line in lines:
        line = line.strip()

        # INSTRUMENTATION_STATUS: key=value
        m = re.match(r"INSTRUMENTATION_STATUS:\s+(\w+)=(.*)", line)
        if m:
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

    return results


def load_tasks(tasks_dir):
    """tester-agent 태스크 JSON 파일들을 로드합니다.

    Returns:
        list[dict]: 태스크 정보 (taskId, testClassFqn, filePath)
    """
    tasks = []
    pattern = os.path.join(tasks_dir, "task_*.json")
    for filepath in sorted(glob.glob(pattern)):
        try:
            with open(filepath, "r", encoding="utf-8") as f:
                data = json.load(f)
        except (json.JSONDecodeError, OSError):
            continue

        if data.get("agent") != "tester-agent":
            continue

        task_id = data.get("taskId", os.path.basename(filepath).replace(".json", ""))
        fqn = data.get("testClassFqn", "")

        # fallback: prompt에서 FQN 추출
        if not fqn:
            m = re.search(r"class\s+([\w.]+)", data.get("prompt", ""))
            if m:
                fqn = m.group(1)

        if fqn:
            tasks.append(
                {"taskId": task_id, "testClassFqn": fqn, "filePath": filepath}
            )

    return tasks


def match_results_to_task(task_fqn, all_results):
    """태스크의 testClassFqn에 해당하는 테스트 결과를 필터링합니다.

    샤딩으로 인해 동일 클래스의 메소드가 여러 샤드에 분산될 수 있으므로
    전체 결과에서 className이 일치하는 것을 모두 수집합니다.
    """
    matched = [r for r in all_results if r["className"] == task_fqn]
    return matched


def build_task_result(task_fqn, matched_results, project_path, module):
    """per-task uitest_results.json 형식의 dict를 생성합니다."""
    total = len(matched_results)
    passed = sum(1 for r in matched_results if r["status"] == "passed")
    failed_tests = []

    for r in matched_results:
        if r["status"] != "passed":
            failed_tests.append(
                {
                    "className": r["className"],
                    "testName": r["testName"],
                    "errorMessage": r.get("errorMessage", ""),
                    "stackTrace": r.get("stackTrace", ""),
                    "testFilePath": "",
                }
            )

    return {
        "platform": "android",
        "projectPath": project_path or "",
        "module": module or "",
        "totalCount": total,
        "passedCount": passed,
        "failedCount": len(failed_tests),
        "failedTests": failed_tests,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Parse am instrument shard logs into per-task JSON results"
    )
    parser.add_argument(
        "--shard-dir",
        default="./test_results",
        help="Directory containing shard_*.log files",
    )
    parser.add_argument(
        "--tasks-dir",
        default=".gemini/agents/tasks",
        help="Directory containing task_*.json files",
    )
    parser.add_argument(
        "--output-dir",
        default=".gemini/agents/logs",
        help="Directory to write per-task result JSON files",
    )
    parser.add_argument(
        "--project-path", default="", help="Relative project path for result metadata"
    )
    parser.add_argument(
        "--module", default="yogiyo", help="Module name for result metadata"
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

    # 2. 태스크 로드
    tasks = load_tasks(args.tasks_dir)
    if not tasks:
        print(f"No tester-agent tasks found in {args.tasks_dir}", file=sys.stderr)
        # 태스크 없이 전체 결과만 출력
        all_result = build_task_result("", all_results, args.project_path, args.module)
        all_result["totalCount"] = total_tests
        all_result["passedCount"] = total_passed
        all_result["failedCount"] = total_failed
        all_result["failedTests"] = [
            {
                "className": r["className"],
                "testName": r["testName"],
                "errorMessage": r.get("errorMessage", ""),
                "stackTrace": r.get("stackTrace", ""),
                "testFilePath": "",
            }
            for r in all_results
            if r["status"] != "passed"
        ]

        os.makedirs(args.output_dir, exist_ok=True)
        out_path = os.path.join(args.output_dir, "all_uitest_results.json")
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(all_result, f, indent=2, ensure_ascii=False)
        print(f"Wrote combined results to: {out_path}")
        return

    # 3. 태스크별 결과 매칭 및 JSON 생성
    os.makedirs(args.output_dir, exist_ok=True)
    written = 0

    for task in tasks:
        task_id = task["taskId"]
        fqn = task["testClassFqn"]

        matched = match_results_to_task(fqn, all_results)

        if not matched:
            # 결과가 없는 경우 (샤딩에서 제외되었거나 실행 안 됨)
            result = {
                "platform": "android",
                "projectPath": args.project_path,
                "module": args.module,
                "totalCount": 0,
                "passedCount": 0,
                "failedCount": 1,
                "failedTests": [
                    {
                        "className": fqn,
                        "testName": "NO_RESULTS",
                        "errorMessage": f"No test results found for {fqn} in shard logs",
                        "stackTrace": "",
                        "testFilePath": "",
                    }
                ],
            }
        else:
            result = build_task_result(fqn, matched, args.project_path, args.module)

        out_path = os.path.join(args.output_dir, f"{task_id}_uitest_results.json")
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(result, f, indent=2, ensure_ascii=False)

        status_str = "PASS" if result["failedCount"] == 0 else "FAIL"
        print(
            f"  {task_id}: {fqn} -> {result['totalCount']} tests, "
            f"{result['failedCount']} failures [{status_str}]"
        )
        written += 1

    print(f"\nWrote {written} per-task result file(s) to {args.output_dir}")


if __name__ == "__main__":
    main()
