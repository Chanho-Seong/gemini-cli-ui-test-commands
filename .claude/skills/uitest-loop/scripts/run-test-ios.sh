#!/usr/bin/env bash
#
# run-test-ios.sh — iOS UI 테스트 실행 (xcodebuild test)
#
# 사용법:
#   bash run-test-ios.sh --output-dir <dir> [OPTIONS]
#
# 옵션:
#   --output-dir <dir>      결과 JSON 출력 디렉토리 (필수)
#   --project <path>        .xcworkspace / .xcodeproj 경로 (default: 현재 디렉토리 자동탐색)
#   --scheme <name>         xcodebuild scheme (default: 자동 추론)
#   --device <udid>         고정 디바이스 UDID (시뮬레이터 or 실기기; 미지정 시 booted 시뮬레이터)
#   --class <fqn>           테스트 클래스. "<TargetName>/<ClassName>" 형식 (반복 가능)
#   --suite <fqn>           테스트 스위트 (xctestplan 이름 또는 XCTestSuite FQN)
#   --method <name>         테스트 메서드 (class 와 함께 지정)
#   --project-path <path>   결과 메타데이터용 (default: .)
#   --dry-run               계획만 출력
#
# 결과: <output-dir>/all_uitest_results.json
#

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[run-test-ios] $*"; }

OUTPUT_DIR=""
PROJECT_PATH=""
SCHEME=""
DEVICE_ID=""
TEST_CLASSES=()
TEST_SUITE=""
TEST_METHOD=""
PROJECT_PATH_META="."
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    "")             shift ;;   # 빈 인자는 무시
    --output-dir)   OUTPUT_DIR="${2:-}"; shift 2 ;;
    --project)      PROJECT_PATH="${2:-}"; shift 2 ;;
    --scheme)       SCHEME="${2:-}"; shift 2 ;;
    --device)       DEVICE_ID="${2:-}"; shift 2 ;;
    --class)        [[ -n "${2:-}" ]] && TEST_CLASSES+=("$2"); shift 2 ;;
    --suite)        TEST_SUITE="${2:-}"; shift 2 ;;
    --method)       TEST_METHOD="${2:-}"; shift 2 ;;
    --project-path) PROJECT_PATH_META="${2:-.}"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)      sed -n '3,21p' "$0"; exit 0 ;;
    *) echo "unknown option: '$1'" >&2; exit 2 ;;
  esac
done

[[ -z "$OUTPUT_DIR" ]] && { echo "--output-dir is required" >&2; exit 2; }
mkdir -p "$OUTPUT_DIR"

LOG_PATH="$OUTPUT_DIR/run-test-ios.log"
RESULT_FILE="$OUTPUT_DIR/all_uitest_results.json"

# ─── Project auto-detect ──────────────────────────────────────────────────
if [[ -z "$PROJECT_PATH" ]]; then
  PROJECT_PATH="$(pwd)"
fi
PROJECT_PATH="$(cd "${PROJECT_PATH%/}" && pwd)"

# 워크스페이스/프로젝트 파일 선택
WORKSPACE_FILE="$(find "$PROJECT_PATH" -maxdepth 2 -name '*.xcworkspace' -not -path '*/Pods*' -not -name 'project.xcworkspace' 2>/dev/null | head -1)"
XCODEPROJ_FILE=""
if [[ -z "$WORKSPACE_FILE" ]]; then
  XCODEPROJ_FILE="$(find "$PROJECT_PATH" -maxdepth 2 -name '*.xcodeproj' 2>/dev/null | head -1)"
fi

if [[ -z "$WORKSPACE_FILE" && -z "$XCODEPROJ_FILE" ]]; then
  log "No .xcworkspace / .xcodeproj found under $PROJECT_PATH"
  exit 1
fi

# ─── Scheme 추론 ──────────────────────────────────────────────────────────
if [[ -z "$SCHEME" ]]; then
  if [[ ${#TEST_CLASSES[@]} -gt 0 ]]; then
    # yogiyoUITests/LoginTest → yogiyoUITests 에서 UITests 제거
    SCHEME="$(echo "${TEST_CLASSES[0]}" | cut -d/ -f1 | sed -E 's/UITests$//')"
  fi
  if [[ -z "$SCHEME" ]]; then
    if [[ -n "$WORKSPACE_FILE" ]]; then
      SCHEME="$(basename "$WORKSPACE_FILE" .xcworkspace)"
    else
      SCHEME="$(basename "$XCODEPROJ_FILE" .xcodeproj)"
    fi
  fi
fi

# ─── Destination ──────────────────────────────────────────────────────────
DEST_ARGS=""
if [[ -n "$DEVICE_ID" ]]; then
  DEST_ARGS="-destination id=$DEVICE_ID"
else
  BOOTED="$(xcrun simctl list devices booted 2>/dev/null | grep -oE '[0-9A-F-]{36}' | head -1 || true)"
  if [[ -n "$BOOTED" ]]; then
    DEST_ARGS="-destination id=$BOOTED"
  else
    DEST_ARGS="-destination platform=iOS Simulator"
  fi
fi

# ─── Project arg ──────────────────────────────────────────────────────────
if [[ -n "$WORKSPACE_FILE" ]]; then
  PROJECT_ARG="-workspace $WORKSPACE_FILE"
else
  PROJECT_ARG="-project $XCODEPROJ_FILE"
fi

# ─── only-testing filter ──────────────────────────────────────────────────
ONLY_TESTING_ARGS=""
for cls in "${TEST_CLASSES[@]:-}"; do
  [[ -z "$cls" ]] && continue
  if [[ -n "$TEST_METHOD" && "$cls" != */* ]]; then
    # <Class>/<Method> 만 지정된 경우 scheme 에 프리픽스 붙일 수 없음 → Target 명시 필요
    ONLY_TESTING_ARGS="$ONLY_TESTING_ARGS -only-testing:${cls}/${TEST_METHOD}"
  elif [[ -n "$TEST_METHOD" ]]; then
    ONLY_TESTING_ARGS="$ONLY_TESTING_ARGS -only-testing:${cls}/${TEST_METHOD}"
  else
    ONLY_TESTING_ARGS="$ONLY_TESTING_ARGS -only-testing:${cls}"
  fi
done

# suite 는 testPlan 이름으로 사용하거나, scheme 의 test plan 선택
TESTPLAN_ARG=""
if [[ -n "$TEST_SUITE" ]]; then
  TESTPLAN_ARG="-testPlan $TEST_SUITE"
fi

# selectionFilter JSON
CLASSES_JSON="$(printf '%s\n' "${TEST_CLASSES[@]:-}" | python3 -c 'import sys,json; print(json.dumps([l for l in sys.stdin.read().splitlines() if l]))')"
export CLASSES_JSON SUITE="$TEST_SUITE" METHOD="$TEST_METHOD"
SELECTION_FILTER_JSON="$(python3 <<'PY'
import json,os
print(json.dumps({
  "classes": json.loads(os.environ.get("CLASSES_JSON","[]")),
  "suite":   os.environ.get("SUITE","") or None,
  "method":  os.environ.get("METHOD","") or None,
}))
PY
)"

CMD="xcodebuild test $PROJECT_ARG -scheme $SCHEME $DEST_ARGS $TESTPLAN_ARG $ONLY_TESTING_ARGS -resultBundlePath $OUTPUT_DIR/Test.xcresult"

if [[ "$DRY_RUN" == "true" ]]; then
  log "[DRY RUN] PLAN:"
  log "  workspace/project: ${WORKSPACE_FILE:-$XCODEPROJ_FILE}"
  log "  scheme: $SCHEME"
  log "  destination: $DEST_ARGS"
  log "  filter: $SELECTION_FILTER_JSON"
  log "  command: $CMD"
  exit 0
fi

: > "$LOG_PATH"
log "RUN: $CMD"

# Clean previous xcresult
rm -rf "$OUTPUT_DIR/Test.xcresult"

TEST_EXIT=0
(
  cd "$PROJECT_PATH"
  eval "$CMD"
) >> "$LOG_PATH" 2>&1 || TEST_EXIT=$?

log "xcodebuild exit: $TEST_EXIT"

# ─── Parse ─────────────────────────────────────────────────────────────────
XCRESULT="$OUTPUT_DIR/Test.xcresult"
if [[ ! -d "$XCRESULT" ]]; then
  # build log 에서 경로 탐색 → DerivedData fallback
  XCRESULT="$(grep -oE '/[^ ]*\.xcresult' "$LOG_PATH" 2>/dev/null | tail -1 || true)"
  if [[ ! -d "$XCRESULT" ]]; then
    XCRESULT="$(find "$HOME/Library/Developer/Xcode/DerivedData" -name '*.xcresult' -type d 2>/dev/null | xargs ls -dt 2>/dev/null | head -1 || true)"
  fi
fi

if [[ -n "$XCRESULT" && -d "$XCRESULT" ]]; then
  python3 "$SCRIPT_DIR/parse-xcresult.py" \
    --xcresult "$XCRESULT" \
    --output-dir "$OUTPUT_DIR" \
    --project-path "$PROJECT_PATH_META" \
    --selection-filter "$SELECTION_FILTER_JSON" \
    >> "$LOG_PATH" 2>&1 || log "parse-xcresult failed"
else
  log "No xcresult found"
  python3 - "$RESULT_FILE" "$PROJECT_PATH_META" "$SELECTION_FILTER_JSON" "$TEST_EXIT" <<'PY'
import json, sys
path, proj, sel, exit_code = sys.argv[1:5]
with open(path, 'w', encoding='utf-8') as f:
    json.dump({
      'platform':'ios','projectPath':proj,'totalCount':0,'passedCount':0,
      'failedCount':0,'failedTests':[],'selectionFilter':json.loads(sel),
      'error': f'xcodebuild exit={exit_code}, no xcresult'
    }, f, indent=2, ensure_ascii=False)
PY
fi

if [[ -f "$RESULT_FILE" ]]; then
  FC="$(python3 -c "import json; print(json.load(open('$RESULT_FILE')).get('failedCount',0))" 2>/dev/null || echo 0)"
  if [[ "$FC" -eq 0 ]]; then
    log "PASS"
    exit 0
  else
    log "FAIL: $FC tests"
    exit 1
  fi
else
  exit 1
fi
