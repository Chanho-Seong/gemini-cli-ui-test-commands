#!/usr/bin/env bash
#
# run-agent-with-retry.sh
# 에이전트를 백그라운드에서 실행하고, 모델 용량 제한 오류 시 다른 모델로 재시도합니다.
#
# 사용법:
#   bin/run-agent-with-retry.sh <agent> <task_id> <log_file> "<prompt>" &
#
# 모델 선택 (최대 3회 재시도, 총 4회 시도):
#   - tester-agent: gemini-3-flash-preview -> gemini-3-pro-preview -> gemini-2.5-pro -> gemini-2.5-flash
#   - coder-agent 등 복잡한 에이전트: gemini-3-pro-preview -> gemini-3-flash-preview -> gemini-2.5-pro -> gemini-2.5-flash
#
# 용량 오류 패턴: MODEL_CAPACITY_EXHAUSTED, No capacity available for model, No Capacity available
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CAPACITY_PATTERNS="MODEL_CAPACITY_EXHAUSTED|No capacity available for model|No Capacity available|RESOURCE_EXHAUSTED|RetryableQuotaError|rateLimitExceeded"

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

# 로그 경로 (상대 경로면 프로젝트 루트 기준)
if [[ "$LOG_FILE" == .gemini/* ]]; then
  LOG_PATH="$PROJECT_ROOT/$LOG_FILE"
else
  LOG_PATH="$PROJECT_ROOT/.gemini/agents/logs/$(basename "$LOG_FILE")"
fi

# 에이전트별 모델 순서 (최대 3회 재시도)
if [[ "$AGENT" == "tester-agent" ]]; then
  MODELS=(gemini-3-flash-preview gemini-2.5-flash gemini-3-pro-preview gemini-2.5-pro)
else
  MODELS=(gemini-3-pro-preview gemini-2.5-pro gemini-3-flash-preview gemini-2.5-flash)
fi
MAX_RETRIES=3

log_contains_capacity_error() {
  [[ -f "$LOG_PATH" ]] || return 1
  # 최근 실행 출력만 검사 (이전 재시도 출력과 혼동 방지)
  tail -100 "$LOG_PATH" | grep -qE "$CAPACITY_PATTERNS" 2>/dev/null
}

run_gemini() {
  local model="$1"
  cd "$PROJECT_ROOT"
  echo "" >> "$LOG_PATH"
  echo "[run-agent-with-retry] Executing: gemini -m $model -e $AGENT -y -p \"$PROMPT\"" >> "$LOG_PATH"
  echo "" >> "$LOG_PATH"
  gemini -m "$model" -e "$AGENT" -y -p "$PROMPT" >> "$LOG_PATH" 2>&1
  return $?
}

# 로그 파일 초기화 (run_gemini 호출 전)
mkdir -p "$(dirname "$LOG_PATH")"
: > "$LOG_PATH"

# 프로세스 종료 시 로그 남기기
log_exit() {
  local code="${1:-0}"
  echo "" >> "$LOG_PATH"
  echo "[run-agent-with-retry] $TASK_ID: Process exited with code $code at $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$LOG_PATH"
  echo "" >> "$LOG_PATH"
}

# 모델 순차 시도 (최대 3회 재시도, 총 4회 시도)
exit_code=0
for i in "${!MODELS[@]}"; do
  model="${MODELS[$i]}"
  run_gemini "$model" || exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    break
  fi
  if [[ $i -lt $(( ${#MODELS[@]} - 1 )) ]] && [[ $i -lt $MAX_RETRIES ]] && log_contains_capacity_error; then
    echo "" >> "$LOG_PATH"
    echo "[run-agent-with-retry] $TASK_ID: $model capacity exhausted, retrying with next model (attempt $((i + 2))/$((MAX_RETRIES + 1)))" >> "$LOG_PATH"
    echo "" >> "$LOG_PATH"
  else
    break
  fi
done

log_exit "$exit_code"
exit $exit_code
