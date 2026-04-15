#!/usr/bin/env bash
#
# run-test-ios.sh — iOS UI 테스트를 직접 실행
#
# 사용법:
#   bin/run-test-ios.sh [OPTIONS]
#
# 옵션:
#   --class <fqn>          실행할 테스트 클래스 (FQCN). 여러 개 지정 가능
#   --project <path>       워크스페이스 내 프로젝트 경로 (기본: 자동 탐색)
#   --output-dir <dir>     결과 JSON 출력 디렉토리 (기본: .gemini/agents/logs)
#   --project-path <path>  결과 메타데이터용 프로젝트 경로 (기본: .)
#   --dry-run              실제 실행 없이 계획만 출력
#
# 동작:
#   1. 디바이스 풀에서 iOS 디바이스 acquire
#   2. xcodebuild test 실행 (클래스별 순차 실행)
#   3. xcresulttool 로 결과 파싱
#   4. all_uitest_results.json 생성
#   5. EXIT trap으로 디바이스 release 보장
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source shared logging utility
source "$SCRIPT_DIR/log-utils.sh"
_LOG_SOURCE="test-ios"

# ─── Usage ──────────────────────────────────────────────────────────────────

usage() {
  echo "Usage: $0 [--class <fqn>...] [--project <path>] [--output-dir <dir>] [--project-path <path>] [--dry-run]"
  echo "  --class          실행할 테스트 클래스 (FQCN). 여러 개 지정 가능"
  echo "                   예: --class MyAppUITests.LoginTest"
  echo "                   예: --class MyAppUITests.LoginTest --class MyAppUITests.HomeTest"
  echo "  --project        워크스페이스 내 Xcode 프로젝트 경로 (기본: 자동 탐색)"
  echo "  --output-dir     결과 JSON 출력 디렉토리 (기본: .gemini/agents/logs)"
  echo "  --project-path   결과 메타데이터용 프로젝트 경로 (기본: .)"
  echo "  --dry-run        실제 실행 없이 계획만 출력"
  exit 1
}

# ─── Arguments ──────────────────────────────────────────────────────────────

TEST_CLASSES=()
PROJECT_PATH=""
OUTPUT_DIR="$PROJECT_ROOT/.gemini/agents/logs"
PROJECT_PATH_META="."
DRY_RUN=false
DEVICE_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class)        TEST_CLASSES+=("$2"); shift 2 ;;
    --project)      PROJECT_PATH="$2"; shift 2 ;;
    --output-dir)   OUTPUT_DIR="$2"; shift 2 ;;
    --project-path) PROJECT_PATH_META="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)      usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

# ─── Log file setup ─────────────────────────────────────────────────────────

LOG_PATH="${RUN_DIR:-$OUTPUT_DIR}/run-test-ios.log"
mkdir -p "$(dirname "$LOG_PATH")"
_LOG_FILE="$LOG_PATH"

RESULT_FILE="${RUN_DIR:-$OUTPUT_DIR}/all_uitest_results.json"

# ─── Helper functions ──────────────────────────────────────────────────────

write_error_result() {
  local error_msg="$1"
  python3 -c "
import json
result = {
    'platform': 'ios',
    'projectPath': '$PROJECT_PATH_META',
    'totalCount': 0,
    'passedCount': 0,
    'failedCount': 0,
    'failedTests': [],
    'error': $(python3 -c "import json; print(json.dumps('''$error_msg'''))" 2>/dev/null || echo "\"$error_msg\"")
}
with open('$RESULT_FILE', 'w') as f:
    json.dump(result, f, indent=2, ensure_ascii=False)
"
}

# ─── Auto-detect project ────────────────────────────────────────────────────

if [[ -z "$PROJECT_PATH" ]]; then
  for dir in "$PROJECT_ROOT/.gemini/agents/workspace"/*/; do
    if [[ -d "$dir" ]] && (ls "$dir"/*.xcworkspace 2>/dev/null || ls "$dir"/*.xcodeproj 2>/dev/null) > /dev/null 2>&1; then
      PROJECT_PATH="$dir"
      break
    fi
  done

  if [[ -z "$PROJECT_PATH" ]]; then
    log_error "No iOS project found in .gemini/agents/workspace/"
    write_error_result "No iOS project found in workspace"
    exit 1
  fi
fi

# Normalize project path
PROJECT_PATH="${PROJECT_PATH%/}"

log_info "Platform: iOS"
log_info "Project: $PROJECT_PATH"
if [[ ${#TEST_CLASSES[@]} -gt 0 ]]; then
  log_info "Test classes: ${TEST_CLASSES[*]}"
else
  log_info "Test classes: (all)"
fi

# ─── Dry run ────────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == "true" ]]; then
  log_info "[DRY RUN] Would execute:"
  log_info "  1. device-pool.sh acquire ios test-ios $$"
  if [[ ${#TEST_CLASSES[@]} -gt 0 ]]; then
    for cls in "${TEST_CLASSES[@]}"; do
      log_info "  2. cd $PROJECT_PATH && xcodebuild test -destination 'id=<device>' -only-testing:.../$cls"
    done
  else
    log_info "  2. cd $PROJECT_PATH && xcodebuild test -destination 'id=<device>'"
  fi
  log_info "  3. xcrun xcresulttool get ..."
  log_info "  4. Write result to $RESULT_FILE"
  exit 0
fi

# ─── Device pool integration ────────────────────────────────────────────────

DEVICE_POOL_SCRIPT="$SCRIPT_DIR/device-pool.sh"

acquire_device() {
  if [[ ! -x "$DEVICE_POOL_SCRIPT" ]]; then
    log_warn "device-pool.sh not found, running without device management"
    return 0
  fi

  log_info "Acquiring iOS device..."

  local max_wait=300  # 5분 대기
  local waited=0
  local interval=10

  while true; do
    DEVICE_ID="$("$DEVICE_POOL_SCRIPT" acquire "ios" "test-ios" "$$" 2>/dev/null)" && break
    waited=$((waited + interval))
    if [[ $waited -ge $max_wait ]]; then
      log_error "Timeout waiting for iOS device (${max_wait}s)"
      return 1
    fi
    log_info "No idle iOS device, waiting... (${waited}s/${max_wait}s)"
    sleep "$interval"
  done

  log_info "Acquired device: $DEVICE_ID"
}

release_device() {
  if [[ -n "$DEVICE_ID" ]] && [[ -x "$DEVICE_POOL_SCRIPT" ]]; then
    log_info "Releasing device: $DEVICE_ID"
    "$DEVICE_POOL_SCRIPT" release "$DEVICE_ID" >> "$LOG_PATH" 2>&1 || true
    DEVICE_ID=""
  fi
}

# EXIT trap: 디바이스 해제 보장
cleanup() {
  local exit_code=$?
  release_device

  if [[ $exit_code -eq 0 ]]; then
    log_info "Completed successfully"
  else
    log_error "Exited with code $exit_code"
  fi
}

trap cleanup EXIT INT TERM

# ─── Acquire device ─────────────────────────────────────────────────────────

acquire_device || exit 1

# ─── Resolve build command ──────────────────────────────────────────────────

if [[ -n "$DEVICE_ID" ]]; then
  DESTINATION="id=$DEVICE_ID"
else
  DESTINATION="platform=iOS Simulator,name=iPhone 15"
fi

# xcworkspace 또는 xcodeproj 자동 탐색
WORKSPACE_FILE="$(find "$PROJECT_PATH" -maxdepth 1 -name '*.xcworkspace' -not -name 'Pods*' | head -1)"
if [[ -n "$WORKSPACE_FILE" ]]; then
  SCHEME="$(basename "$WORKSPACE_FILE" .xcworkspace)"
  BUILD_BASE="xcodebuild test -workspace $WORKSPACE_FILE -scheme $SCHEME -destination '$DESTINATION'"
else
  XCODEPROJ_FILE="$(find "$PROJECT_PATH" -maxdepth 1 -name '*.xcodeproj' | head -1)"
  SCHEME="$(basename "$XCODEPROJ_FILE" .xcodeproj)"
  BUILD_BASE="xcodebuild test -project $XCODEPROJ_FILE -scheme $SCHEME -destination '$DESTINATION'"
fi

# ─── Run tests ──────────────────────────────────────────────────────────────

TEST_EXIT_CODE=0

if [[ ${#TEST_CLASSES[@]} -gt 0 ]]; then
  # 클래스별 -only-testing 인자 구성
  ONLY_TESTING_ARGS=""
  for cls in "${TEST_CLASSES[@]}"; do
    ONLY_TESTING_ARGS="$ONLY_TESTING_ARGS -only-testing:$cls"
  done
  BUILD_CMD="$BUILD_BASE $ONLY_TESTING_ARGS"
else
  BUILD_CMD="$BUILD_BASE"
fi

log_info "[TEST-LOG] START xcodebuild: $BUILD_CMD"

(
  cd "$PROJECT_PATH"
  eval "$BUILD_CMD"
) >> "$LOG_PATH" 2>&1 || TEST_EXIT_CODE=$?

log_info "[TEST-LOG] END xcodebuild: exit $TEST_EXIT_CODE"

# ─── Parse results ──────────────────────────────────────────────────────────

# xcresult 탐색: 빌드 로그에서 경로 추출 → DerivedData 폴백
XCRESULT="$(grep -oE '/[^ ]*\.xcresult' "$LOG_PATH" 2>/dev/null | tail -1)"
if [[ ! -d "$XCRESULT" ]]; then
  XCRESULT="$(find ~/Library/Developer/Xcode/DerivedData -name '*.xcresult' -type d 2>/dev/null | xargs ls -dt 2>/dev/null | head -1)"
fi

if [[ -n "$XCRESULT" ]]; then
  log_info "[TEST-LOG] START parse: $XCRESULT"

  python3 "$SCRIPT_DIR/parse-xcresult.py" \
    --xcresult "$XCRESULT" \
    --output-dir "$(dirname "$RESULT_FILE")" \
    --project-path "$PROJECT_PATH_META" \
    >> "$LOG_PATH" 2>&1

  log_info "[TEST-LOG] END parse: wrote results to $RESULT_FILE"
else
  log_warn "No .xcresult bundle found"
  write_error_result "No xcresult found (xcodebuild exit code: $TEST_EXIT_CODE)"
fi

log_info "Results written to: $RESULT_FILE"

# ─── Final result ──────────────────────────────────────────────────────────

echo "------------------------------------------"
if [[ -f "$RESULT_FILE" ]]; then
  FAILED_COUNT="$(python3 -c "import json; print(json.load(open('$RESULT_FILE')).get('failedCount', 0))" 2>/dev/null || echo 0)"
  if [[ "$FAILED_COUNT" -eq 0 ]]; then
    echo "[FINAL RESULT] 모든 UI 테스트가 성공적으로 완료되었습니다!"
    exit 0
  else
    echo "[FINAL RESULT] 일부 테스트가 실패했습니다. (실패 수: $FAILED_COUNT)"
    echo "[INFO] 자세한 내용은 $RESULT_FILE 을 확인하세요."
    exit 1
  fi
else
  echo "[FINAL RESULT] 결과 파일이 생성되지 않았습니다."
  exit 1
fi
