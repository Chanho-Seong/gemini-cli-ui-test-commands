#!/usr/bin/env python3
"""
create-test-tasks-ios.py — iOS UITest 태스크 생성 스크립트

iOS 프로젝트에서 UITest 클래스를 찾아 tester-agent 태스크 JSON 파일을 생성합니다.

사용법:
  python3 bin/create-test-tasks-ios.py                          # 기본: --testplan Regression
  python3 bin/create-test-tasks-ios.py --testplan Regression    # xctestplan에서 테스트 타겟 스캔
  python3 bin/create-test-tasks-ios.py --class GlobalHomeUITests  # 특정 클래스
  python3 bin/create-test-tasks-ios.py --pattern "*Home*"       # 파일명 패턴

옵션:
  --testplan <name>  xctestplan 파일에서 테스트 타겟 디렉토리 스캔 (기본: Regression)
  --class <name>     특정 테스트 클래스 (반복 가능)
  --pattern <glob>   테스트 파일명 패턴 매칭 (예: *Home*)
"""

import argparse
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
WORKSPACE_DIR = PROJECT_ROOT / ".gemini" / "agents" / "workspace"
TASKS_DIR = PROJECT_ROOT / ".gemini" / "agents" / "tasks"
PLANS_DIR = PROJECT_ROOT / ".gemini" / "agents" / "plans"


def find_ios_project():
    """workspace 내 iOS 프로젝트 탐색 (.xcworkspace 또는 .xcodeproj)"""
    for d in WORKSPACE_DIR.iterdir():
        if not d.is_dir():
            continue
        has_workspace = any(d.glob("*.xcworkspace"))
        has_project = any(d.glob("*.xcodeproj"))
        if has_workspace or has_project:
            return d
    return None


def find_uitest_dirs(project_path):
    """UITest 타겟 디렉토리 탐색 (*UITest* 패턴)"""
    dirs = []
    for d in project_path.iterdir():
        if d.is_dir() and "UITest" in d.name:
            dirs.append(d)
    return dirs


def is_test_class(filepath):
    """파일이 실제 테스트 클래스인지 확인 (XCTestCase 상속 + func test 존재)"""
    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()
    has_inheritance = ": XCTestCase" in content or ": XCUI_TestBase" in content
    has_test_method = bool(re.search(r"func\s+test", content))
    return has_inheritance and has_test_method


def extract_class_name(filepath):
    """Swift 파일에서 클래스명 추출"""
    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()
    match = re.search(r"class\s+(\w+)\s*:", content)
    if match:
        return match.group(1)
    return filepath.stem


def _find_uitest_target_name(filepath, project_path):
    """파일 경로에서 UITest 타겟 디렉토리명 추출"""
    rel = filepath.relative_to(project_path)
    for part in rel.parts:
        if "UITest" in part:
            return part
    return None


def find_test_files(uitest_dir):
    """UITest 타겟 디렉토리 내에서 *Test*.swift 파일 검색"""
    results = []
    for f in uitest_dir.rglob("*Test*.swift"):
        if is_test_class(f):
            results.append(f)
    return results


def resolve_testplan(testplan_name, project_path):
    """xctestplan 파일에서 테스트 타겟 디렉토리를 찾아 타겟/클래스명 목록 반환"""
    # xctestplan 파일 찾기
    candidates = list(project_path.rglob(f"*{testplan_name}*.xctestplan"))
    if not candidates:
        print(f"  [WARN] No xctestplan found for '{testplan_name}'", file=sys.stderr)
        return []

    testplan_file = candidates[0]
    print(f"  Found testplan: {testplan_file.relative_to(PROJECT_ROOT)}")

    with open(testplan_file, "r", encoding="utf-8") as f:
        plan_data = json.load(f)

    # testTargets에서 타겟 이름 추출
    target_names = []
    for target_entry in plan_data.get("testTargets", []):
        target = target_entry.get("target", {})
        name = target.get("name", "")
        if name:
            target_names.append(name)

    if not target_names:
        print(f"  [WARN] No test targets found in testplan", file=sys.stderr)
        return []

    # selectedTests 필드 확인
    selected_tests = None
    for target_entry in plan_data.get("testTargets", []):
        st = target_entry.get("selectedTests", None)
        if st is not None:
            selected_tests = st
            break

    # 타겟 디렉토리에서 테스트 클래스 스캔 (xcodebuild -only-testing:Target/Class 포맷)
    class_names = []
    for target_name in target_names:
        target_dir = project_path / target_name
        if not target_dir.is_dir():
            print(f"  [WARN] Target directory not found: {target_name}", file=sys.stderr)
            continue

        print(f"  Scanning target: {target_name}")
        test_files = find_test_files(target_dir)

        for f in test_files:
            cls = extract_class_name(f)
            if selected_tests is not None:
                if cls in selected_tests or any(cls in s for s in selected_tests):
                    class_names.append(f"{target_name}/{cls}")
            else:
                class_names.append(f"{target_name}/{cls}")

    return class_names


def resolve_class(class_name, project_path):
    """클래스 이름으로 파일을 찾아 검증, Target/Class 포맷으로 반환"""
    for f in project_path.rglob(f"{class_name}.swift"):
        if is_test_class(f):
            cls = extract_class_name(f)
            # UITest 타겟 디렉토리명 추출 (파일이 속한 *UITest* 디렉토리)
            target_name = _find_uitest_target_name(f, project_path)
            if target_name:
                return [f"{target_name}/{cls}"]
            return [cls]
    print(f"  [WARN] Cannot find test class '{class_name}'", file=sys.stderr)
    return []


def resolve_pattern(pattern, project_path):
    """글로브 패턴으로 테스트 파일 매칭 → Target/Class 리스트"""
    uitest_dirs = find_uitest_dirs(project_path)
    class_names = []
    for uitest_dir in uitest_dirs:
        target_name = uitest_dir.name
        for f in uitest_dir.rglob(f"{pattern}.swift"):
            if is_test_class(f):
                cls = extract_class_name(f)
                class_names.append(f"{target_name}/{cls}")
    return class_names


def create_task(task_id, test_class_name, now_iso):
    """태스크 JSON 및 plan 파일 생성"""
    TASKS_DIR.mkdir(parents=True, exist_ok=True)
    PLANS_DIR.mkdir(parents=True, exist_ok=True)

    prompt = (
        f"You are the tester-agent. Your Task ID is {task_id}. "
        f"Run UI test for class {test_class_name} and write results to "
        f".gemini/agents/logs/{task_id}_uitest_results.json. "
        f"Create .gemini/agents/tasks/{task_id}.done when finished."
    )

    task = {
        "taskId": task_id,
        "status": "pending",
        "agent": "tester-agent",
        "testClassFqn": test_class_name,
        "prompt": prompt,
        "planFile": f".gemini/agents/plans/{task_id}_plan.md",
        "logFile": f".gemini/agents/logs/{task_id}.log",
        "createdAt": now_iso,
    }

    task_file = TASKS_DIR / f"{task_id}.json"
    with open(task_file, "w", encoding="utf-8") as f:
        json.dump(task, f, ensure_ascii=False, indent=2)

    plan_file = PLANS_DIR / f"{task_id}_plan.md"
    with open(plan_file, "w", encoding="utf-8") as f:
        f.write(f"# Plan for tester-agent - Run {test_class_name}\n\n")
        f.write(f"Test class: `{test_class_name}`\n")

    return task_id


def main():
    parser = argparse.ArgumentParser(description="Create tester-agent tasks for iOS UITests")
    parser.add_argument("--testplan", type=str, help="xctestplan name (default: Regression)")
    parser.add_argument("--class", dest="classes", action="append", default=[], help="Test class name (repeatable)")
    parser.add_argument("--pattern", type=str, help="Filename glob pattern (e.g. *Home*)")
    args = parser.parse_args()

    # 기본값: --testplan Regression
    has_args = args.testplan or args.classes or args.pattern
    if not has_args:
        args.testplan = "Regression"

    # 프로젝트 탐색
    project_path = find_ios_project()
    if not project_path:
        print("ERROR: No iOS project found in .gemini/agents/workspace/", file=sys.stderr)
        sys.exit(1)

    print(f"Project: {project_path.relative_to(PROJECT_ROOT)}")

    # 클래스명 수집
    all_classes = []

    if args.testplan:
        print(f"Resolving testplan: {args.testplan}")
        classes = resolve_testplan(args.testplan, project_path)
        print(f"  Resolved {len(classes)} classes from testplan")
        all_classes.extend(classes)

    for cls in args.classes:
        print(f"Resolving class: {cls}")
        classes = resolve_class(cls, project_path)
        all_classes.extend(classes)

    if args.pattern:
        print(f"Resolving pattern: {args.pattern}")
        classes = resolve_pattern(args.pattern, project_path)
        print(f"  Matched {len(classes)} classes")
        all_classes.extend(classes)

    # 중복 제거 (순서 유지)
    seen = set()
    unique_classes = []
    for cls in all_classes:
        if cls not in seen:
            seen.add(cls)
            unique_classes.append(cls)

    if not unique_classes:
        print("ERROR: No test classes resolved. Check arguments.", file=sys.stderr)
        sys.exit(1)

    # 태스크 생성
    base_ts = int(time.time())
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    print(f"\nCreating {len(unique_classes)} tasks:")
    created = []
    for i, cls in enumerate(unique_classes):
        task_id = f"task_{base_ts}_{i}"
        create_task(task_id, cls, now_iso)
        print(f"  [{i+1}/{len(unique_classes)}] {task_id} -> {cls}")
        created.append((task_id, cls))

    print(f"\nDone. Created {len(created)} tester-agent tasks.")
    for task_id, cls in created:
        print(f"  {task_id}: {cls}")


if __name__ == "__main__":
    main()
