#!/usr/bin/env bash
#
# run-test-ios.sh — Gemini API 없이 iOS UI 테스트를 직접 실행
#
# tester-agent가 하던 역할(xcodebuild 실행 → 결과 파싱 → JSON 생성)을
# 셸 스크립트로 직접 수행하여 Gemini API 용량 소모를 방지합니다.
#
# 사용법:
#   bin/run-test-ios.sh <task_id> <test_class_fqn> [OPTIONS]
#
# 옵션:
#   --project <path>       워크스페이스 내 프로젝트 경로 (기본: 자동 탐색)
#   --dry-run              실제 실행 없이 계획만 출력
#
# 동작:
#   1. 디바이스 풀에서 iOS 디바이스 acquire
#   2. xcodebuild test 실행
#   3. xcresulttool 로 결과 파싱
#   4. .gemini/agents/logs/<task_id>_uitest_results.json 생성
#   5. .gemini/agents/tasks/<task_id>.done 생성
#   6. EXIT trap으로 디바이스 release 보장
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TASKS_DIR="$PROJECT_ROOT/.gemini/agents/tasks"
LOGS_DIR="$PROJECT_ROOT/.gemini/agents/logs"

# Source shared logging utility
source "$SCRIPT_DIR/log-utils.sh"
_LOG_SOURCE="test-ios"

# ─── Arguments ──────────────────────────────────────────────────────────────

usage() {
  echo "Usage: $0 <task_id> <test_class_fqn> [--project <path>] [--dry-run]" >&2
  exit 1
}

[[ $# -ge 2 ]] || usage

TASK_ID="$1"
TEST_CLASS_FQN="$2"
shift 2

PROJECT_PATH=""
DRY_RUN=false
DEVICE_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)   PROJECT_PATH="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=true; shift ;;
    *) shift ;;
  esac
done

# ─── Log file setup ─────────────────────────────────────────────────────────

if [[ -n "${RUN_DIR:-}" ]]; then
  LOG_PATH="$RUN_DIR/${TASK_ID}.log"
  # 기존 logFile 경로 호환을 위한 symlink
  local_legacy_path="$LOGS_DIR/${TASK_ID}.log"
  mkdir -p "$(dirname "$local_legacy_path")"
  ln -sf "$LOG_PATH" "$local_legacy_path"
else
  LOG_PATH="$LOGS_DIR/${TASK_ID}.log"
fi

mkdir -p "$(dirname "$LOG_PATH")"
_LOG_FILE="$LOG_PATH"

RESULT_FILE="${RUN_DIR:-$LOGS_DIR}/${TASK_ID}_uitest_results.json"

# ─── Helper functions ──────────────────────────────────────────────────────

write_fallback_result() {
  local error_msg="$1"
  python3 -c "
import json
result = {
    'platform': 'ios',
    'projectPath': '${RELATIVE_PROJECT_PATH:-}',
    'totalCount': 0,
    'passedCount': 0,
    'failedCount': 1,
    'failedTests': [{
        'className': '$TEST_CLASS_FQN',
        'testName': 'EXECUTION_ERROR',
        'errorMessage': $(python3 -c "import json; print(json.dumps('''$error_msg'''))" 2>/dev/null || echo "\"$error_msg\""),
        'stackTrace': '',
        'testFilePath': ''
    }],
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
    python3 -c "
import json
result = {
    'platform': 'ios',
    'projectPath': '',
    'totalCount': 0,
    'passedCount': 0,
    'failedCount': 0,
    'failedTests': [],
    'error': 'No iOS project found in workspace'
}
with open('$RESULT_FILE', 'w') as f:
    json.dump(result, f, indent=2, ensure_ascii=False)
"
    mkdir -p "$TASKS_DIR"
    touch "$TASKS_DIR/${TASK_ID}.done"
    exit 1
  fi
fi

# Normalize project path
PROJECT_PATH="${PROJECT_PATH%/}"
RELATIVE_PROJECT_PATH="${PROJECT_PATH#$PROJECT_ROOT/}"

log_info "Task: $TASK_ID"
log_info "Test class: $TEST_CLASS_FQN"
log_info "Platform: iOS"
log_info "Project: $RELATIVE_PROJECT_PATH"

# ─── Dry run ────────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == "true" ]]; then
  log_info "[DRY RUN] Would execute:"
  log_info "  1. device-pool.sh acquire ios $TASK_ID $$"
  log_info "  2. cd $PROJECT_PATH && xcodebuild test -destination 'id=<device>' -only-testing:.../$TEST_CLASS_FQN"
  log_info "  3. xcrun xcresulttool get ..."
  log_info "  4. Write result to $RESULT_FILE"
  log_info "  5. Create $TASKS_DIR/${TASK_ID}.done"
  exit 0
fi

# ─── Device pool integration ────────────────────────────────────────────────

DEVICE_POOL_SCRIPT="$SCRIPT_DIR/device-pool.sh"

acquire_device() {
  if [[ ! -x "$DEVICE_POOL_SCRIPT" ]]; then
    log_warn "device-pool.sh not found, running without device management"
    return 0
  fi

  log_info "Acquiring iOS device for $TASK_ID..."

  local max_wait=300  # 5분 대기
  local waited=0
  local interval=10

  while true; do
    DEVICE_ID="$("$DEVICE_POOL_SCRIPT" acquire "ios" "$TASK_ID" "$$" 2>/dev/null)" && break
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

# EXIT trap: 디바이스 해제 + 상태 업데이트 보장
cleanup() {
  local exit_code=$?
  release_device

  # 태스크 상태를 complete 또는 failed로 업데이트
  if [[ -f "$TASKS_DIR/${TASK_ID}.json" ]]; then
    local new_status="complete"
    [[ $exit_code -ne 0 ]] && new_status="failed"
    python3 -c "
import json
with open('$TASKS_DIR/${TASK_ID}.json') as f: d = json.load(f)
d['status'] = '$new_status'
with open('$TASKS_DIR/${TASK_ID}.json', 'w') as f: json.dump(d, f, ensure_ascii=False)
" 2>/dev/null || true
  fi

  if [[ $exit_code -eq 0 ]]; then
    log_info "$TASK_ID: Completed successfully"
  else
    log_error "$TASK_ID: Exited with code $exit_code"
  fi
}

trap cleanup EXIT INT TERM

# ─── Acquire device ─────────────────────────────────────────────────────────

acquire_device || exit 1

# ─── Run tests ──────────────────────────────────────────────────────────────

TEST_EXIT_CODE=0

log_info "Running iOS test: $TEST_CLASS_FQN"

XCODEBUILD_ARGS="-only-testing:$TEST_CLASS_FQN"
if [[ -n "$DEVICE_ID" ]]; then
  DESTINATION="id=$DEVICE_ID"
else
  DESTINATION="platform=iOS Simulator,name=iPhone 15"
fi

# xcworkspace 또는 xcodeproj 자동 탐색
WORKSPACE_FILE="$(find "$PROJECT_PATH" -maxdepth 1 -name '*.xcworkspace' -not -name 'Pods*' | head -1)"
if [[ -n "$WORKSPACE_FILE" ]]; then
  SCHEME="$(basename "$WORKSPACE_FILE" .xcworkspace)"
  BUILD_CMD="xcodebuild test -workspace $WORKSPACE_FILE -scheme $SCHEME -destination '$DESTINATION' $XCODEBUILD_ARGS"
else
  XCODEPROJ_FILE="$(find "$PROJECT_PATH" -maxdepth 1 -name '*.xcodeproj' | head -1)"
  SCHEME="$(basename "$XCODEPROJ_FILE" .xcodeproj)"
  BUILD_CMD="xcodebuild test -project $XCODEPROJ_FILE -scheme $SCHEME -destination '$DESTINATION' $XCODEBUILD_ARGS"
fi

log_info "[TEST-LOG] START xcodebuild: $BUILD_CMD"

(
  cd "$PROJECT_PATH"
  eval "$BUILD_CMD"
) >> "$LOG_PATH" 2>&1 || TEST_EXIT_CODE=$?

log_info "[TEST-LOG] END xcodebuild: exit $TEST_EXIT_CODE"

# ─── Parse results ──────────────────────────────────────────────────────────

XCRESULT="$(find "$PROJECT_PATH" -name '*.xcresult' -newer "$LOG_PATH" 2>/dev/null | head -1)"

if [[ -n "$XCRESULT" ]]; then
  log_info "[TEST-LOG] START parse: xcrun xcresulttool get --path $XCRESULT"

  python3 -c "
import json, subprocess, sys

result_path = '$XCRESULT'
try:
    raw = subprocess.check_output(
        ['xcrun', 'xcresulttool', 'get', '--path', result_path, '--format', 'json'],
        text=True
    )
    data = json.loads(raw)

    failed_tests = []
    total = 0
    passed = 0

    def walk_tests(node, class_name=''):
        nonlocal total, passed
        if 'subtests' in node:
            name = node.get('name', {}).get('_value', class_name)
            for sub in node['subtests']['_values']:
                walk_tests(sub, name)
        elif 'testStatus' in node:
            total += 1
            status = node['testStatus']['_value']
            test_name = node.get('name', {}).get('_value', '')
            if status == 'Success':
                passed += 1
            else:
                msg = ''
                if 'summaryRef' in node:
                    msg = node.get('summaryRef', {}).get('_value', '')
                failed_tests.append({
                    'className': class_name,
                    'testName': test_name,
                    'errorMessage': msg,
                    'stackTrace': '',
                    'testFilePath': ''
                })

    actions = data.get('actions', {}).get('_values', [])
    for action in actions:
        testsRef = action.get('actionResult', {}).get('testsRef', {})
        if testsRef:
            tests_id = testsRef.get('id', {}).get('_value', '')
            if tests_id:
                tests_raw = subprocess.check_output(
                    ['xcrun', 'xcresulttool', 'get', '--path', result_path,
                     '--format', 'json', '--id', tests_id],
                    text=True
                )
                tests_data = json.loads(tests_raw)
                for suite in tests_data.get('summaries', {}).get('_values', []):
                    for group in suite.get('testableSummaries', {}).get('_values', []):
                        for test in group.get('tests', {}).get('_values', []):
                            walk_tests(test)

    output = {
        'platform': 'ios',
        'projectPath': '$RELATIVE_PROJECT_PATH',
        'totalCount': total,
        'passedCount': passed,
        'failedCount': len(failed_tests),
        'failedTests': failed_tests
    }
    with open('$RESULT_FILE', 'w') as f:
        json.dump(output, f, indent=2, ensure_ascii=False)
    print(f'Parsed {total} tests, {len(failed_tests)} failures')
except Exception as e:
    print(f'Error parsing xcresult: {e}', file=sys.stderr)
    output = {
        'platform': 'ios',
        'projectPath': '$RELATIVE_PROJECT_PATH',
        'totalCount': 0,
        'passedCount': 0,
        'failedCount': 0,
        'failedTests': [],
        'error': str(e)
    }
    with open('$RESULT_FILE', 'w') as f:
        json.dump(output, f, indent=2, ensure_ascii=False)
" >> "$LOG_PATH" 2>&1

  log_info "[TEST-LOG] END parse: wrote results to $RESULT_FILE"
else
  log_warn "No .xcresult bundle found"
  write_fallback_result "No xcresult found (xcodebuild exit code: $TEST_EXIT_CODE)"
fi

# ─── Create sentinel file ───────────────────────────────────────────────────

touch "$TASKS_DIR/${TASK_ID}.done"
log_info "Created sentinel: $TASKS_DIR/${TASK_ID}.done"
log_info "Results written to: $RESULT_FILE"

exit 0
