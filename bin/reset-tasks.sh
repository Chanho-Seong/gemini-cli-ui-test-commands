#!/usr/bin/env bash
#
# reset-tasks.sh — 태스크 초기화 스크립트
#
# 실행 중이거나 완료/실패한 태스크를 정리하고 pending 상태로 되돌립니다.
# 관련 프로세스가 살아있으면 종료하고, 로그/sentinel/잠금 파일을 정리합니다.
#
# 사용법:
#   bin/reset-tasks.sh                    # 모든 태스크 초기화 (running/complete/failed → pending)
#   bin/reset-tasks.sh --running          # running 상태 태스크만 초기화
#   bin/reset-tasks.sh --agent tester-agent  # 특정 에이전트 태스크만 초기화
#   bin/reset-tasks.sh --clean            # 태스크/로그/플랜 파일 전부 삭제 (완전 초기화)
#   bin/reset-tasks.sh --dry-run          # 실제 변경 없이 계획만 출력
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TASKS_DIR="$PROJECT_ROOT/.gemini/agents/tasks"
LOGS_DIR="$PROJECT_ROOT/.gemini/agents/logs"
PLANS_DIR="$PROJECT_ROOT/.gemini/agents/plans"
LOCKS_DIR="$PROJECT_ROOT/.gemini/agents/state/locks"

# Source shared logging utility
source "$SCRIPT_DIR/log-utils.sh"
_LOG_SOURCE="reset"

# ─── Arguments ──────────────────────────────────────────────────────────────

MODE="reset"          # reset | clean
FILTER_STATUS=""      # "" = all, "running" = running only
FILTER_AGENT=""       # "" = all agents
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --running)    FILTER_STATUS="running"; shift ;;
    --agent)      FILTER_AGENT="$2"; shift 2 ;;
    --clean)      MODE="clean"; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    -h|--help)
      head -17 "$0" | grep '^#' | sed 's/^# *//'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ─── Helper functions ──────────────────────────────────────────────────────

# 태스크 관련 프로세스 찾기 및 종료
kill_task_processes() {
  local task_id="$1"

  # run-agent-with-retry.sh, run-test-android|run-test-ios-2.sh, gemini CLI 프로세스 검색
  local pids
  pids=$(ps aux | grep -E "(run-agent-with-retry|run-test-android|run-test-ios|gemini).*${task_id}" | grep -v grep | awk '{print $2}' || true)

  if [[ -n "$pids" ]]; then
    for pid in $pids; do
      if kill -0 "$pid" 2>/dev/null; then
        if [[ "$DRY_RUN" == "true" ]]; then
          log_info "[DRY RUN] Would kill PID $pid for $task_id"
        else
          log_info "Killing PID $pid for $task_id"
          kill "$pid" 2>/dev/null || true
          # 1초 대기 후에도 살아있으면 SIGKILL
          sleep 1
          kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
        fi
      fi
    done
    return 0
  fi
  return 1  # 프로세스 없음
}

# 디바이스 잠금 해제 (태스크 ID 기반)
release_device_locks() {
  local task_id="$1"
  [[ -d "$LOCKS_DIR" ]] || return 0

  for lock_dir in "$LOCKS_DIR"/*.lock.d; do
    [[ -d "$lock_dir" ]] || continue
    local info_file="$lock_dir/info.json"
    [[ -f "$info_file" ]] || continue

    local locked_by
    locked_by="$(python3 -c "import json; print(json.load(open('$info_file')).get('taskId',''))" 2>/dev/null || echo "")"

    if [[ "$locked_by" == "$task_id" ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would release device lock: $(basename "$lock_dir")"
      else
        log_info "Releasing device lock: $(basename "$lock_dir")"
        rm -rf "$lock_dir"
      fi
    fi
  done
}

# 태스크 관련 로그 파일 삭제
clean_task_logs() {
  local task_id="$1"

  # 로그 디렉토리 내 태스크 관련 파일
  for f in "$LOGS_DIR"/${task_id}*; do
    [[ -f "$f" ]] || continue
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[DRY RUN] Would remove: $(basename "$f")"
    else
      rm -f "$f"
      log_info "Removed: $(basename "$f")"
    fi
  done

  # RUN_DIR 내 파일도 탐색
  for run_dir in "$LOGS_DIR"/run_*/; do
    [[ -d "$run_dir" ]] || continue
    for f in "$run_dir"/${task_id}*; do
      [[ -f "$f" ]] || continue
      if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would remove: $(basename "$run_dir")/$(basename "$f")"
      else
        rm -f "$f"
        log_info "Removed: $(basename "$run_dir")/$(basename "$f")"
      fi
    done
  done
}

# sentinel 파일(.done, .failed) 삭제
clean_sentinel_files() {
  local task_id="$1"
  for ext in done failed; do
    local sentinel="$TASKS_DIR/${task_id}.${ext}"
    if [[ -f "$sentinel" ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would remove: $(basename "$sentinel")"
      else
        rm -f "$sentinel"
        log_info "Removed: $(basename "$sentinel")"
      fi
    fi
  done
}

# 태스크 상태를 pending으로 초기화
reset_task_status() {
  local task_file="$1" task_id="$2"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would reset $task_id → pending"
  else
    python3 -c "
import json
with open('$task_file') as f: d = json.load(f)
d['status'] = 'pending'
with open('$task_file', 'w') as f: json.dump(d, f, indent=2, ensure_ascii=False)
"
    log_info "Reset $task_id → pending"
  fi
}

# ─── Main: Clean mode (전부 삭제) ──────────────────────────────────────────

if [[ "$MODE" == "clean" ]]; then
  log_info "=== Full cleanup: removing all tasks, logs, plans, locks ==="

  # 먼저 모든 실행 중 프로세스 종료
  for task_file in "$TASKS_DIR"/task_*.json; do
    [[ -f "$task_file" ]] || continue
    local task_id
    task_id="$(python3 -c "import json; print(json.load(open('$task_file')).get('taskId',''))" 2>/dev/null || echo "")"
    [[ -n "$task_id" ]] && kill_task_processes "$task_id" || true
  done

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would remove all task_*.json, task_*.done, task_*.failed"
    log_info "[DRY RUN] Would remove all task_*_plan.md"
    log_info "[DRY RUN] Would remove all task_*.log, task_*_uitest_results.json"
    log_info "[DRY RUN] Would remove all device locks"
  else
    # Tasks
    rm -f "$TASKS_DIR"/task_*.json "$TASKS_DIR"/task_*.done "$TASKS_DIR"/task_*.failed
    log_info "Removed all task files"

    # Plans
    rm -f "$PLANS_DIR"/task_*_plan.md
    log_info "Removed all plan files"

    # Logs (태스크 관련만, backup.zip 등은 보존)
    rm -f "$LOGS_DIR"/task_*.log "$LOGS_DIR"/task_*_uitest_results.json
    for run_dir in "$LOGS_DIR"/run_*/; do
      [[ -d "$run_dir" ]] || continue
      rm -f "$run_dir"/task_*.log "$run_dir"/task_*_uitest_results.json
    done
    log_info "Removed all task log files"

    # Device locks
    if [[ -d "$LOCKS_DIR" ]]; then
      rm -rf "$LOCKS_DIR"/*.lock.d
      log_info "Removed all device locks"
    fi
  fi

  log_info "=== Cleanup complete ==="
  exit 0
fi

# ─── Main: Reset mode (상태 초기화) ────────────────────────────────────────

log_info "=== Task Reset ==="
[[ -n "$FILTER_STATUS" ]] && log_info "Filter: status=$FILTER_STATUS"
[[ -n "$FILTER_AGENT" ]]  && log_info "Filter: agent=$FILTER_AGENT"

reset_count=0
skip_count=0

for task_file in "$TASKS_DIR"/task_*.json; do
  [[ -f "$task_file" ]] || continue

  local_task_id="$(python3 -c "import json; print(json.load(open('$task_file')).get('taskId',''))" 2>/dev/null || echo "")"
  local_agent="$(python3 -c "import json; print(json.load(open('$task_file')).get('agent',''))" 2>/dev/null || echo "")"
  local_status="$(python3 -c "import json; print(json.load(open('$task_file')).get('status',''))" 2>/dev/null || echo "")"

  # 필터 적용
  if [[ -n "$FILTER_AGENT" && "$local_agent" != "$FILTER_AGENT" ]]; then
    skip_count=$((skip_count + 1))
    continue
  fi

  if [[ -n "$FILTER_STATUS" && "$local_status" != "$FILTER_STATUS" ]]; then
    skip_count=$((skip_count + 1))
    continue
  fi

  # 이미 pending이면 스킵
  if [[ "$local_status" == "pending" && -z "$FILTER_STATUS" ]]; then
    log_info "$local_task_id: already pending, skipping"
    skip_count=$((skip_count + 1))
    continue
  fi

  log_info "Processing $local_task_id (agent=$local_agent, status=$local_status)"

  # 1. 프로세스 종료
  if kill_task_processes "$local_task_id"; then
    log_info "  Killed related processes"
  else
    log_info "  No related processes found"
  fi

  # 2. 디바이스 잠금 해제
  release_device_locks "$local_task_id"

  # 3. sentinel 파일 삭제
  clean_sentinel_files "$local_task_id"

  # 4. 로그 파일 삭제
  clean_task_logs "$local_task_id"

  # 5. 상태를 pending으로 초기화
  reset_task_status "$task_file" "$local_task_id"

  reset_count=$((reset_count + 1))
done

log_info "=== Reset complete: $reset_count reset, $skip_count skipped ==="
