#!/usr/bin/env bash
#
# run-agent-with-retry.sh
# 에이전트를 백그라운드에서 실행하고, 모델 용량 제한 오류 시 다른 모델로 재시도합니다.
#
# 사용법:
#   bin/run-agent-with-retry.sh <agent> <task_id> <log_file> "<prompt>" [--device-os <os>] &
#
# 모델 선택 (최대 3회 재시도, 총 4회 시도):
#   gemini-3-pro-preview -> gemini-2.5-pro -> gemini-3-flash-preview -> gemini-2.5-flash
#   (tester-agent는 run-test-android.sh로 대체됨 — 이 스크립트는 verifier/coder/pr-agent용)
#
# 디바이스 풀 연동 (--device-os 옵션):
#   tester-agent, verifier-agent 실행 시 자동으로 디바이스를 acquire/release 합니다.
#   --device-os android|ios 를 지정하면 해당 OS의 디바이스를 점유합니다.
#
# 용량 오류 패턴: MODEL_CAPACITY_EXHAUSTED, No capacity available for model, No Capacity available
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CAPACITY_PATTERNS="MODEL_CAPACITY_EXHAUSTED|No capacity available for model|No Capacity available|RESOURCE_EXHAUSTED|RetryableQuotaError|rateLimitExceeded"

# Source shared logging utility
source "$SCRIPT_DIR/log-utils.sh"
_LOG_SOURCE="retry"

usage() {
  echo "Usage: $0 <agent> <task_id> <log_file> \"<prompt>\"" >&2
  echo "  agent:   tester-agent, coder-agent, verifier-agent, reviewer-agent, etc." >&2
  echo "  task_id: e.g. task_123" >&2
  echo "  log_file: e.g. .gemini/agents/logs/task_123.log" >&2
  echo "  prompt:  Full prompt string for the agent" >&2
  exit 1
}

[[ $# -ge 4 ]] || usage

AGENT="$1"
TASK_ID="$2"
LOG_FILE="$3"
PROMPT="$4"

# task_id 유효성 검사: task_ 접두어 필수 (인자 순서 오류 방지)
if [[ ! "$TASK_ID" =~ ^task_ ]]; then
  echo "Error: Invalid task_id '$TASK_ID'. Must start with 'task_'." >&2
  echo "Hint: Check argument order — $0 <agent> <task_id> <log_file> \"<prompt>\"" >&2
  exit 1
fi
DEVICE_OS=""
DEVICE_ID=""

# Parse optional --device-os flag
shift 4
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device-os) DEVICE_OS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Auto-detect device OS for device-bound agents
if [[ -z "$DEVICE_OS" ]] && [[ "$AGENT" == "verifier-agent" ]]; then
  # Default to android if not specified
  DEVICE_OS="android"
fi

# 로그 경로: RUN_DIR이 설정되어 있으면 해당 디렉토리에 기록, 아니면 기존 방식
if [[ -n "${RUN_DIR:-}" ]]; then
  LOG_PATH="$RUN_DIR/$(basename "$LOG_FILE")"
  # 기존 logFile 경로 호환을 위한 symlink
  local_legacy_path="$PROJECT_ROOT/.gemini/agents/logs/$(basename "$LOG_FILE")"
  mkdir -p "$(dirname "$local_legacy_path")"
  ln -sf "$LOG_PATH" "$local_legacy_path"
elif [[ "$LOG_FILE" == .gemini/* ]]; then
  LOG_PATH="$PROJECT_ROOT/$LOG_FILE"
else
  LOG_PATH="$PROJECT_ROOT/.gemini/agents/logs/$(basename "$LOG_FILE")"
fi

_LOG_FILE="$LOG_PATH"

# 에이전트별 모델 순서 (최대 3회 재시도)
# tester-agent는 run-test-android.sh로 대체되어 더 이상 Gemini API를 사용하지 않음
MODELS=(gemini-3-pro-preview gemini-2.5-pro gemini-3-flash-preview gemini-2.5-flash)
MAX_RETRIES=3

log_contains_capacity_error() {
  [[ -f "$LOG_PATH" ]] || return 1
  # 최근 실행 출력만 검사 (이전 재시도 출력과 혼동 방지)
  tail -100 "$LOG_PATH" | grep -qE "$CAPACITY_PATTERNS" 2>/dev/null
}

run_gemini() {
  local model="$1"
  cd "$PROJECT_ROOT"
  log_info "Executing: gemini -m $model -e $AGENT -y -p \"$PROMPT\""
  gemini -m "$model" -e "$AGENT" -y -p "$PROMPT" >> "$LOG_PATH" 2>&1
  return $?
}

# 로그 파일 초기화 (이전 시도 로그가 있으면 보존하고 구분선 추가)
mkdir -p "$(dirname "$LOG_PATH")"
if [[ -s "$LOG_PATH" ]]; then
  {
    echo ""
    echo "================================================================================"
    log_info "NEW ATTEMPT (previous content preserved above)"
    echo "================================================================================"
    echo ""
  } >> "$LOG_PATH"
else
  : > "$LOG_PATH"
fi

# ─── 디바이스 풀 연동 ───────────────────────────────────────────────────────
DEVICE_POOL_SCRIPT="$SCRIPT_DIR/device-pool.sh"

acquire_device() {
  if [[ -z "$DEVICE_OS" ]] || [[ ! -x "$DEVICE_POOL_SCRIPT" ]]; then
    return 0
  fi

  log_info "Acquiring $DEVICE_OS device for $TASK_ID..."

  local max_wait=300  # 5분 대기
  local waited=0
  local interval=10

  while true; do
    DEVICE_ID="$("$DEVICE_POOL_SCRIPT" acquire "$DEVICE_OS" "$TASK_ID" "$$" 2>/dev/null)" && break
    waited=$((waited + interval))
    if [[ $waited -ge $max_wait ]]; then
      log_error "Timeout waiting for $DEVICE_OS device (${max_wait}s)"
      return 1
    fi
    log_info "No idle $DEVICE_OS device, waiting... (${waited}s/${max_wait}s)"
    sleep "$interval"
  done

  log_info "Acquired device: $DEVICE_ID"

  # Inject device ID into prompt for the agent
  if [[ -n "$DEVICE_ID" ]]; then
    PROMPT="$PROMPT [DEVICE_ID=$DEVICE_ID] Use this specific device for test execution. For Android: set ANDROID_SERIAL=$DEVICE_ID before running gradlew. For iOS: use -destination 'id=$DEVICE_ID'."
  fi
}

release_device() {
  if [[ -n "$DEVICE_ID" ]] && [[ -x "$DEVICE_POOL_SCRIPT" ]]; then
    log_info "Releasing device: $DEVICE_ID"
    "$DEVICE_POOL_SCRIPT" release "$DEVICE_ID" >> "$LOG_PATH" 2>&1 || true
    DEVICE_ID=""
  fi
}

# 프로세스 종료 시 로그 남기기 + 디바이스 해제
log_exit() {
  local code="${1:-0}"
  release_device
  if [[ "$code" -eq 0 ]]; then
    log_info "$TASK_ID: Process exited with code $code"
  else
    log_error "$TASK_ID: Process exited with code $code"
  fi
}

# trap으로 비정상 종료 시에도 디바이스 해제 보장
trap 'release_device' EXIT INT TERM

# 디바이스 획득 (device-bound agents)
acquire_device || { log_exit 1; exit 1; }

# 모델 순차 시도 (최대 3회 재시도, 총 4회 시도)
exit_code=0
for i in "${!MODELS[@]}"; do
  model="${MODELS[$i]}"
  run_gemini "$model" || exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    break
  fi
  if [[ $i -lt $(( ${#MODELS[@]} - 1 )) ]] && [[ $i -lt $MAX_RETRIES ]] && log_contains_capacity_error; then
    log_warn "$TASK_ID: $model capacity exhausted, retrying with next model (attempt $((i + 2))/$((MAX_RETRIES + 1)))"
    echo "--- Model retry: switching from $model to ${MODELS[$((i + 1))]} ---" >> "$LOG_PATH"
  else
    break
  fi
done

log_exit "$exit_code"
exit $exit_code
