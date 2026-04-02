#!/usr/bin/env python3
"""
create-test-tasks.py — 테스트 태스크 생성 스크립트

Suite/Class/Pattern 모드로 테스트 클래스를 해석하고,
각 클래스에 대한 tester-agent 태스크 JSON 파일을 생성합니다.

사용법:
  python3 bin/create-test-tasks.py [--suite <name>] [--class <fqn>...] [--pattern <glob>]
  python3 bin/create-test-tasks.py                     # 기본: --suite SanitySuite

옵션:
  --suite <name>     Suite 파일에서 @Suite.SuiteClasses 파싱 (기본: CriticalRTSuite)
  --class <name>     특정 테스트 클래스 (FQN 또는 단순 이름, 복수 지정 가능)
  --pattern <glob>   테스트 파일명 패턴 매칭 (예: *Home*)
"""

import argparse
import glob
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


def find_android_project():
    """workspace 내 Android 프로젝트 탐색"""
    for d in WORKSPACE_DIR.iterdir():
        if not d.is_dir():
            continue
        if (d / "build.gradle").exists() or (d / "build.gradle.kts").exists():
            return d
    return None


def find_test_source_dirs(project_path):
    """androidTest 소스 디렉토리 탐색"""
    dirs = []
    for root, dirnames, filenames in os.walk(project_path):
        if "androidTest" in Path(root).parts:
            dirs.append(Path(root))
    return dirs


def find_test_files(project_path, pattern="**/*Test*.kt"):
    """테스트 파일 검색 (Kotlin/Java)"""
    results = []
    for ext in ["kt", "java"]:
        p = pattern.rsplit(".", 1)[0] if "." in pattern else pattern
        for f in project_path.rglob(f"{p}.{ext}"):
            if "androidTest" in f.parts:
                results.append(f)
    return results


def read_package(filepath):
    """파일에서 package 문 추출"""
    with open(filepath, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line.startswith("package "):
                return line.replace("package ", "").rstrip(";").strip()
    return None


def is_suite_file(filepath):
    """@Suite.SuiteClasses 어노테이션이 있는지 확인"""
    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()
    return "@Suite.SuiteClasses" in content or "@SuiteClasses" in content


def parse_suite(filepath):
    """Suite 파일에서 import 맵 + @Suite.SuiteClasses 내 클래스 목록을 파싱하여 FQN 리스트 반환"""
    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()

    # import 문 파싱: import kr.co.yogiyo.xxx.ClassName -> {ClassName: FQN}
    import_map = {}
    for m in re.finditer(r"^import\s+([\w.]+)", content, re.MULTILINE):
        fqn = m.group(1)
        simple_name = fqn.rsplit(".", 1)[-1]
        # org.junit 등 테스트 프레임워크 import 제외
        if not fqn.startswith(("org.junit", "android.", "androidx.test")):
            import_map[simple_name] = fqn

    # @Suite.SuiteClasses(...) 내부 파싱
    suite_match = re.search(
        r"@Suite\.SuiteClasses\s*\((.*?)\)", content, re.DOTALL
    )
    if not suite_match:
        suite_match = re.search(
            r"@SuiteClasses\s*\((.*?)\)", content, re.DOTALL
        )
    if not suite_match:
        return []

    suite_body = suite_match.group(1)
    # ClassName::class 패턴 추출
    class_refs = re.findall(r"(\w+)::class", suite_body)

    fqns = []
    for class_name in class_refs:
        if class_name in import_map:
            fqns.append(import_map[class_name])
        else:
            print(f"  [WARN] Cannot resolve FQN for '{class_name}' — not found in imports", file=sys.stderr)
    return fqns


def resolve_suite(suite_name, project_path):
    """Suite 이름으로 파일을 찾아 FQN 리스트 반환"""
    candidates = []
    for ext in ["kt", "java"]:
        candidates.extend(project_path.rglob(f"*{suite_name}*.{ext}"))

    # androidTest 디렉토리 내 파일만 필터
    candidates = [f for f in candidates if "androidTest" in f.parts]

    for f in candidates:
        if is_suite_file(f):
            print(f"  Found suite file: {f.relative_to(PROJECT_ROOT)}")
            return parse_suite(f)

    print(f"  [WARN] No suite file found for '{suite_name}'", file=sys.stderr)
    return []


def resolve_class(class_name, project_path):
    """클래스 이름을 FQN으로 해석"""
    if "." in class_name:
        return [class_name]  # 이미 FQN

    # 단순 이름 → 파일 검색
    for ext in ["kt", "java"]:
        for f in project_path.rglob(f"{class_name}.{ext}"):
            if "androidTest" in f.parts:
                pkg = read_package(f)
                if pkg:
                    return [f"{pkg}.{class_name}"]
    print(f"  [WARN] Cannot find file for class '{class_name}'", file=sys.stderr)
    return []


def is_test_class(filepath):
    """파일이 실제 테스트 클래스인지 확인 (@Test 또는 @RunWith 어노테이션 존재)"""
    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()
    return "@Test" in content or "@RunWith" in content


def resolve_pattern(pattern, project_path):
    """글로브 패턴으로 테스트 파일 매칭 → FQN 리스트"""
    fqns = []
    for ext in ["kt", "java"]:
        for f in project_path.rglob(f"{pattern}.{ext}"):
            if "androidTest" not in f.parts:
                continue
            if is_suite_file(f):
                continue
            if not is_test_class(f):
                continue
            class_name = f.stem
            pkg = read_package(f)
            if pkg:
                fqns.append(f"{pkg}.{class_name}")
    return fqns


def create_task(task_id, test_class_fqn, now_iso):
    """태스크 JSON 및 plan 파일 생성"""
    TASKS_DIR.mkdir(parents=True, exist_ok=True)
    PLANS_DIR.mkdir(parents=True, exist_ok=True)

    simple_name = test_class_fqn.rsplit(".", 1)[-1]
    prompt = (
        f"You are the tester-agent. Your Task ID is {task_id}. "
        f"Run UI test for class {test_class_fqn} and write results to "
        f".gemini/agents/logs/{task_id}_uitest_results.json. "
        f"Create .gemini/agents/tasks/{task_id}.done when finished."
    )

    task = {
        "taskId": task_id,
        "status": "pending",
        "agent": "tester-agent",
        "testClassFqn": test_class_fqn,
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
        f.write(f"# Plan for tester-agent - Run {simple_name}\n\n")
        f.write(f"Test class: `{test_class_fqn}`\n")

    return task_id


def main():
    parser = argparse.ArgumentParser(description="Create tester-agent tasks from suite/class/pattern")
    parser.add_argument("--suite", type=str, help="Suite name (default: CriticalRTSuite)")
    parser.add_argument("--class", dest="classes", action="append", default=[], help="Test class name (repeatable)")
    parser.add_argument("--pattern", type=str, help="Filename glob pattern (e.g. *Home*)")
    args = parser.parse_args()

    # 기본값: --suite CriticalRTSuite
    has_args = args.suite or args.classes or args.pattern
    if not has_args:
        args.suite = "SanitySuite"

    # 프로젝트 탐색
    project_path = find_android_project()
    if not project_path:
        print("ERROR: No Android project found in .gemini/agents/workspace/", file=sys.stderr)
        sys.exit(1)

    print(f"Project: {project_path.relative_to(PROJECT_ROOT)}")

    # FQN 수집 (union)
    all_fqns = []

    if args.suite:
        print(f"Resolving suite: {args.suite}")
        fqns = resolve_suite(args.suite, project_path)
        print(f"  Resolved {len(fqns)} classes from suite")
        all_fqns.extend(fqns)

    for cls in args.classes:
        print(f"Resolving class: {cls}")
        fqns = resolve_class(cls, project_path)
        all_fqns.extend(fqns)

    if args.pattern:
        print(f"Resolving pattern: {args.pattern}")
        fqns = resolve_pattern(args.pattern, project_path)
        print(f"  Matched {len(fqns)} classes")
        all_fqns.extend(fqns)

    # 중복 제거 (순서 유지)
    seen = set()
    unique_fqns = []
    for fqn in all_fqns:
        if fqn not in seen:
            seen.add(fqn)
            unique_fqns.append(fqn)

    if not unique_fqns:
        print("ERROR: No test classes resolved. Check arguments.", file=sys.stderr)
        sys.exit(1)

    # 태스크 생성
    base_ts = int(time.time())
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    print(f"\nCreating {len(unique_fqns)} tasks:")
    created = []
    for i, fqn in enumerate(unique_fqns):
        task_id = f"task_{base_ts}_{i}"
        create_task(task_id, fqn, now_iso)
        simple_name = fqn.rsplit(".", 1)[-1]
        print(f"  [{i+1}/{len(unique_fqns)}] {task_id} → {simple_name} ({fqn})")
        created.append((task_id, fqn))

    print(f"\nDone. Created {len(created)} tester-agent tasks.")
    for task_id, fqn in created:
        print(f"  {task_id}: {fqn}")


if __name__ == "__main__":
    main()
