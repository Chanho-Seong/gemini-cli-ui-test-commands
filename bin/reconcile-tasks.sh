#!/usr/bin/env bash
#
# Task reconciliation script for gemini-cli agent tasks.
# - Detects failed running tasks from log files
# - Resets status to pending and creates .failed file with retry count and error logs
# - Supports cron scheduling (default: 5 min interval)
#
# Requires: jq (https://stedolan.github.io/jq/)
#

set -e

CRON_MARKER="# gemini-agents-reconcile-tasks"
FAILURE_PATTERNS="MODEL_CAPACITY_EXHAUSTED|No capacity available for model|Max attempts reached|RetryableQuotaError|RESOURCE_EXHAUSTED|An unexpected critical error occurred|rateLimitExceeded|Process exited with code [1-9][0-9]*"

# Resolve script dir and project root (bin is under project root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TASKS_DIR="$PROJECT_ROOT/.gemini/agents/tasks"

# Source shared logging utility
source "$SCRIPT_DIR/log-utils.sh"
_LOG_SOURCE="reconcile"

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "  (no args)     Run task reconciliation"
  echo "  --schedule [MINUTES]  Schedule cron (default: 5 min)"
  echo "  --show-schedule      Show current cron schedule"
}

log_contains_failure() {
  local log_path="$1"
  [[ -f "$log_path" ]] || return 1
  grep -qE "$FAILURE_PATTERNS" "$log_path" 2>/dev/null
}

get_log_path() {
  local log_file="$1"
  if [[ "$log_file" == .gemini/* ]]; then
    echo "$PROJECT_ROOT/${log_file#/}"
  else
    echo "$PROJECT_ROOT/.gemini/agents/logs/$(basename "$log_file")"
  fi
}

DEVICE_POOL_SCRIPT="$SCRIPT_DIR/device-pool.sh"

# Release device lock for a task (find lock by taskId)
release_device_for_task() {
  local task_id="$1"
  local locks_dir="$PROJECT_ROOT/.gemini/agents/state/locks"
  [[ -d "$locks_dir" ]] || return 0

  for lock_dir in "$locks_dir"/*.lock.d; do
    [[ -d "$lock_dir" ]] || continue
    [[ -f "$lock_dir/info.json" ]] || continue

    local locked_by
    if [[ "$USE_JQ" -eq 1 ]]; then
      locked_by="$(jq -r '.taskId // ""' "$lock_dir/info.json" 2>/dev/null)"
    else
      locked_by="$(python3 -c "import json; print(json.load(open('$lock_dir/info.json')).get('taskId',''))" 2>/dev/null || echo "")"
    fi

    if [[ "$locked_by" == "$task_id" ]]; then
      local device_id
      device_id="$(basename "$lock_dir" .lock.d)"
      if [[ -x "$DEVICE_POOL_SCRIPT" ]]; then
        "$DEVICE_POOL_SCRIPT" release "$device_id" 2>/dev/null || rm -rf "$lock_dir"
      else
        rm -rf "$lock_dir"
      fi
      log_info "Released device $device_id (was locked by $task_id)"
    fi
  done
}

reconcile_tasks() {
  [[ -d "$TASKS_DIR" ]] || return 0

  # Also run device pool cleanup if available
  if [[ -x "$DEVICE_POOL_SCRIPT" ]]; then
    "$DEVICE_POOL_SCRIPT" cleanup 2>/dev/null || true
  fi

  for task_file in "$TASKS_DIR"/task_*.json; do
    [[ -f "$task_file" ]] || continue
    [[ "$(basename "$task_file")" == task_*.json ]] || continue

    status="$(jq_read status "$task_file")"
    [[ "$status" == "running" ]] || continue

    task_id="$(jq_read taskId "$task_file")"
    [[ -n "$task_id" ]] || task_id="$(basename "$task_file" .json)"

    log_file="$(jq_read logFile "$task_file")"
    [[ -n "$log_file" ]] || continue

    log_path="$(get_log_path "$log_file")"
    log_contains_failure "$log_path" || continue

    # Release any device lock held by this task
    release_device_for_task "$task_id"

    # Reset status to pending, remove pid
    jq_del_status_pending "$task_file" > "${task_file}.tmp"
    mv "${task_file}.tmp" "$task_file"

    # Create or update .failed file
    failed_path="$TASKS_DIR/${task_id}.failed"
    excerpt_tmp="$(mktemp)"
    tail -50 "$log_path" 2>/dev/null | head -c 2000 > "$excerpt_tmp"

    if [[ -f "$failed_path" ]]; then
      retry_count="$(jq_read retryCount "$failed_path")"
    fi
    retry_count="${retry_count:-0}"
    retry_count=$((retry_count + 1))
    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    jq_update_failed "$failed_path" "$timestamp" "$excerpt_tmp" > "${failed_path}.tmp"
    mv "${failed_path}.tmp" "$failed_path"
    rm -f "$excerpt_tmp"

    log_warn "$task_id: running -> pending (retry #$retry_count)"
  done
}

has_existing_cron() {
  local line
  line="$(crontab -l 2>/dev/null | grep -E "$CRON_MARKER|reconcile-tasks\.(sh|py)" || true)"
  if [[ -n "$line" ]]; then
    echo "$line"
    return 0
  fi
  return 1
}

setup_cron() {
  local interval_min="${1:-5}"
  [[ "$interval_min" -lt 1 ]] && interval_min=1
  [[ "$interval_min" -gt 59 ]] && interval_min=59

  local existing
  if existing="$(has_existing_cron)"; then
    echo "이미 예약된 cron이 있습니다:"
    echo "  $existing"
    return 0
  fi

  local entry="*/${interval_min} * * * * cd $PROJECT_ROOT && $SCRIPT_DIR/reconcile-tasks.sh"
  local full_entry="${entry} $CRON_MARKER"

  local current
  current="$(crontab -l 2>/dev/null || true)"
  [[ -n "$current" ]] && current="${current}"$'\n'
  echo "${current}${full_entry}" | crontab -

  echo "cron 예약 완료:"
  echo "  $full_entry"
}

show_schedule() {
  local existing
  if existing="$(has_existing_cron)"; then
    echo "현재 예약된 cron:"
    echo "  $existing"
  else
    echo "예약된 cron이 없습니다. --schedule 옵션으로 예약하세요."
  fi
}

# Check for jq or python3 (for JSON handling)
if command -v jq &>/dev/null; then
  USE_JQ=1
elif command -v python3 &>/dev/null; then
  USE_JQ=0
else
  echo "Error: jq or python3 is required for JSON handling. Install jq: brew install jq" >&2
  exit 1
fi

# JSON helpers (jq or python fallback)
jq_read() {
  local key="$1"
  local file="$2"
  if [[ "$USE_JQ" -eq 1 ]]; then
    jq -r ".${key} // \"\"" "$file" 2>/dev/null
  else
    python3 -c "import json; d=json.load(open('$file')); print(d.get('$key',''))" 2>/dev/null || echo ""
  fi
}

jq_del_status_pending() {
  local file="$1"
  if [[ "$USE_JQ" -eq 1 ]]; then
    jq 'del(.pid) | .status = "pending"' "$file"
  else
    python3 -c "
import json
with open('$file') as f: d=json.load(f)
d.pop('pid',None)
d['status']='pending'
print(json.dumps(d,ensure_ascii=False))
" 2>/dev/null
  fi
}

jq_update_failed() {
  local failed_path="$1"
  local timestamp="$2"
  local excerpt_file="$3"
  if [[ "$USE_JQ" -eq 1 ]]; then
    if [[ -f "$failed_path" ]]; then
      jq --arg ts "$timestamp" --rawfile ex "$excerpt_file" \
        '.retryCount = (.retryCount // 0) + 1 | .errors += [{"timestamp": $ts, "excerpt": $ex}]' \
        "$failed_path"
    else
      jq -n --arg ts "$timestamp" --rawfile ex "$excerpt_file" \
        '{retryCount: 1, errors: [{"timestamp": $ts, "excerpt": $ex}]}'
    fi
  else
    python3 -c "
import json
from pathlib import Path
p=Path('$failed_path')
excerpt=Path('$excerpt_file').read_text(encoding='utf-8',errors='replace')[:2000]
data=json.loads(p.read_text()) if p.exists() else {'retryCount':0,'errors':[]}
data['retryCount']=data.get('retryCount',0)+1
data.setdefault('errors',[]).append({'timestamp':'$timestamp','excerpt':excerpt})
print(json.dumps(data,ensure_ascii=False,indent=2))
" 2>/dev/null
  fi
}

# Parse args
case "${1:-}" in
  --schedule)
    setup_cron "${2:-5}"
    ;;
  --show-schedule)
    show_schedule
    ;;
  -h|--help)
    usage
    ;;
  "")
    reconcile_tasks
    ;;
  *)
    echo "Unknown option: $1" >&2
    usage >&2
    exit 1
    ;;
esac
