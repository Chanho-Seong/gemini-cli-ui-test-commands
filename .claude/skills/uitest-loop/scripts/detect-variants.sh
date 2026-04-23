#!/usr/bin/env bash
#
# detect-variants.sh — Android 프로젝트에서 사용 가능한 buildVariant 목록을 감지.
#
# 사용법:
#   bash detect-variants.sh [--module <name>] [--prefer debug|beta|release]
#
# 출력(JSON):
#   {
#     "module": "app",
#     "variants": ["debug", "googleDebug", "googleBeta", "release", ...],
#     "recommended": "googleDebug"
#   }
#
# 우선순위: debug → *Debug → *Beta → 첫번째
#
# 감지 방법:
#   1. (빠름) 모듈 build.gradle* 에서 productFlavors + buildTypes 조합 추정
#   2. (정확함) `./gradlew :<module>:tasks --all` 에서 `assemble*AndroidTest` 태스크 추출
#
# Gradle 호출은 시간이 걸리므로 --fast 옵션으로 1번만 사용하도록 강제 가능.
#

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODULE=""
PREFER="debug"
FAST=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    "") shift ;;
    --module)  MODULE="${2:-}"; shift 2 ;;
    --prefer)  PREFER="${2:-debug}"; shift 2 ;;
    --fast)    FAST=true; shift ;;
    -h|--help) sed -n '3,22p' "$0"; exit 0 ;;
    *) echo "unknown option: '$1'" >&2; exit 2 ;;
  esac
done

if [[ -z "$MODULE" ]]; then
  eval "$(bash "$SCRIPT_DIR/detect-platform.sh")"
  MODULE="${MAIN_MODULE:-app}"
  [[ "$MODULE" == "." ]] && MODULE="app"
fi

MODULE_PATH="${MODULE//://}"

collect_from_build_gradle() {
  local gradle_file=""
  for f in "$MODULE_PATH/build.gradle" "$MODULE_PATH/build.gradle.kts"; do
    [[ -f "$f" ]] && { gradle_file="$f"; break; }
  done
  [[ -z "$gradle_file" ]] && return 1

  python3 - "$gradle_file" <<'PY'
import re, sys, json
with open(sys.argv[1], 'r', encoding='utf-8', errors='replace') as f:
    text = f.read()

# productFlavors 이름 추출
flavors = []
# Groovy/KTS: create("google") { ... } 또는 google { ... }
pf_block_match = re.search(r'productFlavors\s*\{(.*?)^\s*\}', text, re.S | re.M)
if pf_block_match:
    body = pf_block_match.group(1)
    # create("name") or name {
    for m in re.finditer(r'(?:create\s*\(\s*["\']|^\s*)(\w+)\s*(?:["\']\s*\)?\s*\{|\{)', body, re.M):
        n = m.group(1)
        if n not in ('dimension',) and not n.startswith('_'):
            flavors.append(n)

# buildTypes: debug / release 는 기본 포함. 나머지는 block 에서 추출
build_types = {'debug', 'release'}
bt_block_match = re.search(r'buildTypes\s*\{(.*?)^\s*\}', text, re.S | re.M)
if bt_block_match:
    body = bt_block_match.group(1)
    for m in re.finditer(r'(?:create\s*\(\s*["\']|^\s*)(\w+)\s*(?:["\']\s*\)?\s*\{|\{)', body, re.M):
        build_types.add(m.group(1))

variants = []
if flavors:
    for fl in flavors:
        for bt in build_types:
            variants.append(fl + bt[0].upper() + bt[1:])
else:
    variants = sorted(build_types)

print(json.dumps(list(dict.fromkeys(variants))))
PY
}

collect_from_gradle_tasks() {
  [[ ! -x "./gradlew" ]] && return 1
  # assemble<Variant>AndroidTest 패턴에서 variant 추출
  local tasks
  tasks="$(./gradlew ":${MODULE}:tasks" --all --console=plain 2>/dev/null || true)"
  [[ -z "$tasks" ]] && return 1

  echo "$tasks" \
    | awk '/^assemble[A-Z][A-Za-z0-9]*AndroidTest\b/ { print $1 }' \
    | sed -E 's/^assemble(.+)AndroidTest$/\1/' \
    | awk '{ v = tolower(substr($1,1,1)) substr($1,2); print v }' \
    | sort -u
}

# 1. build.gradle 추정 시도
VARIANTS_JSON="$(collect_from_build_gradle 2>/dev/null || echo '[]')"

# 2. fast 모드 아니면 gradlew 로 보강
if [[ "$FAST" != true ]]; then
  EXTRA="$(collect_from_gradle_tasks 2>/dev/null || true)"
  if [[ -n "$EXTRA" ]]; then
    VARIANTS_JSON="$(python3 - "$VARIANTS_JSON" <<PY
import json, sys
existing = json.loads(sys.argv[1])
extra = """$EXTRA""".split()
merged = list(dict.fromkeys(extra + existing))
print(json.dumps(merged))
PY
)"
  fi
fi

RECOMMENDED="$(python3 - "$VARIANTS_JSON" "$PREFER" <<'PY'
import json, sys
variants = json.loads(sys.argv[1])
prefer = sys.argv[2].lower()
if not variants:
    print("")
    sys.exit(0)
# 우선순위:
# 1. exact match of prefer (e.g. "debug")
# 2. variant ending with Prefer (case-insensitive): googleDebug, googleBeta
# 3. variant containing prefer
# 4. first
for v in variants:
    if v.lower() == prefer:
        print(v); sys.exit(0)
for v in variants:
    if v.lower().endswith(prefer):
        print(v); sys.exit(0)
for v in variants:
    if prefer in v.lower():
        print(v); sys.exit(0)
print(variants[0])
PY
)"

python3 - "$MODULE" "$VARIANTS_JSON" "$RECOMMENDED" <<'PY'
import json, sys
print(json.dumps({
  "module": sys.argv[1],
  "variants": json.loads(sys.argv[2]),
  "recommended": sys.argv[3],
}, indent=2, ensure_ascii=False))
PY
