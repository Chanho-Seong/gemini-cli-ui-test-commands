#!/usr/bin/env python3
"""
resolve-test-class.py — 메서드 이름으로 테스트 클래스를 자동 감지

사용법:
  python3 resolve-test-class.py --platform android --root <module-path>  --method <name>
  python3 resolve-test-class.py --platform ios     --root <project-path> --method <name>

출력 (stdout, 단일 라인):
  Android: 감지된 테스트 클래스의 FQN            (예: com.example.LoginTest)
  iOS:     "<TargetName>/<ClassName>" 형식 문자열 (예: MyAppUITests/LoginTest)

Exit codes:
  0 — 유일 매칭, FQN stdout 출력
  2 — 매칭 없음 (stderr 에 사유 출력)
  3 — 매칭 2건 이상 (stderr 에 후보 나열 — 사용자가 --class 로 지명)
"""

import argparse
import re
import sys
from pathlib import Path


# ─── Android ──────────────────────────────────────────────────────────────
KT_METHOD_RE = None   # lazy-compiled per invocation
JAVA_METHOD_RE = None
KT_CLASS_RE = re.compile(
    r'^\s*(?:abstract\s+|open\s+|public\s+|internal\s+|final\s+|sealed\s+|data\s+)*class\s+(\w+)'
)
JAVA_CLASS_RE = re.compile(
    r'^\s*(?:public\s+|abstract\s+|final\s+|static\s+)*class\s+(\w+)'
)
PACKAGE_RE = re.compile(r'^\s*package\s+([\w.]+)')


def find_android(module_path: Path, method: str):
    kt_method = re.compile(
        rf'^\s*(?:private\s+|public\s+|internal\s+|protected\s+|open\s+|override\s+|suspend\s+)*fun\s+{re.escape(method)}\s*\('
    )
    java_method = re.compile(
        rf'\bpublic\s+(?:static\s+|final\s+)*void\s+{re.escape(method)}\s*\('
    )

    src_root = module_path / 'src'
    if not src_root.exists():
        return []

    candidates = []
    for p in list(src_root.rglob('*.kt')) + list(src_root.rglob('*.java')):
        if '/androidTest' not in str(p).replace('\\', '/'):
            continue
        try:
            lines = p.read_text(encoding='utf-8', errors='replace').splitlines()
        except Exception:
            continue

        package = ''
        for line in lines:
            m = PACKAGE_RE.match(line)
            if m:
                package = m.group(1)
                break

        is_kt = p.suffix == '.kt'
        method_re = kt_method if is_kt else java_method
        class_re = KT_CLASS_RE if is_kt else JAVA_CLASS_RE

        for i, line in enumerate(lines):
            match = method_re.match(line) if is_kt else method_re.search(line)
            if not match:
                continue
            # 최근 10줄 내에 @Test 어노테이션 존재 확인 (JUnit4/5 공통)
            if not any('@Test' in lines[j] for j in range(max(0, i - 10), i)):
                continue
            # 선행 라인에서 가장 가까운 class 선언 탐색
            class_name = None
            for j in range(i - 1, -1, -1):
                mc = class_re.match(lines[j])
                if mc:
                    class_name = mc.group(1)
                    break
            if not class_name:
                continue
            fqn = f'{package}.{class_name}' if package else class_name
            candidates.append((fqn, str(p), i + 1))

    return _dedupe(candidates)


# ─── iOS ──────────────────────────────────────────────────────────────────
SWIFT_CLASS_RE = re.compile(
    r'^\s*(?:open\s+|public\s+|final\s+|internal\s+|@\w+\s+)*class\s+(\w+)\s*:\s*([\w\s.,]+)'
)


def find_ios(project_root: Path, method: str):
    swift_method = re.compile(
        rf'^\s*(?:open\s+|public\s+|private\s+|internal\s+|final\s+|override\s+)*func\s+{re.escape(method)}\s*\('
    )

    candidates = []
    for p in project_root.rglob('*.swift'):
        s = str(p).replace('\\', '/')
        if any(x in s for x in ('/Pods/', '/DerivedData/', '/.build/', '/Carthage/', '/.git/')):
            continue
        try:
            lines = p.read_text(encoding='utf-8', errors='replace').splitlines()
        except Exception:
            continue

        for i, line in enumerate(lines):
            if not swift_method.match(line):
                continue
            class_name, is_xctest = None, False
            for j in range(i - 1, -1, -1):
                mc = SWIFT_CLASS_RE.match(lines[j])
                if mc:
                    class_name = mc.group(1)
                    is_xctest = 'XCTestCase' in mc.group(2)
                    break
            if not class_name or not is_xctest:
                continue
            target = _infer_ios_target(p)
            candidates.append((f'{target}/{class_name}', str(p), i + 1))

    return _dedupe(candidates)


def _infer_ios_target(file_path: Path) -> str:
    for parent in file_path.parents:
        n = parent.name
        if n.endswith('UITests') or n.endswith('Tests'):
            return n
    return file_path.parent.name


def _dedupe(items):
    seen = set()
    result = []
    for it in items:
        if it[0] in seen:
            continue
        seen.add(it[0])
        result.append(it)
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--platform', required=True, choices=['android', 'ios'])
    ap.add_argument('--root', required=True)
    ap.add_argument('--method', required=True)
    args = ap.parse_args()

    root = Path(args.root).resolve()
    if not root.exists():
        print(f'root path not found: {root}', file=sys.stderr)
        sys.exit(2)

    cands = find_android(root, args.method) if args.platform == 'android' else find_ios(root, args.method)

    if not cands:
        print(f"no test class found for method '{args.method}' under {root}", file=sys.stderr)
        print("check: (1) @Test annotation present (Android), (2) class : XCTestCase (iOS), "
              "(3) method name spelled correctly, (4) file is under androidTest*/UITests*", file=sys.stderr)
        sys.exit(2)

    if len(cands) > 1:
        print(f"ambiguous: multiple classes define '{args.method}':", file=sys.stderr)
        for fqn, path, line in cands:
            print(f'  - {fqn}  ({path}:{line})', file=sys.stderr)
        print('specify --class explicitly to disambiguate', file=sys.stderr)
        sys.exit(3)

    print(cands[0][0])


if __name__ == '__main__':
    main()
