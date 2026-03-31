#!/usr/bin/env bash
#
# run-pipeline.sh — 전체 UITest 파이프라인 오케스트레이터
#
# 워크플로우:
#   1. discover devices    → 디바이스 풀 초기화
#   2. test-planing        → tester-agent 태스크 생성
#   3. run-all(tester)     → 디바이스 풀 제한 병렬 테스트 실행
#   4. aggregate           → 결과 집계
#   5. verify              → verifier-agent 2차 검증 (디바이스 풀 제한)
#   6. fix                 → coder-agent 수정
#   7. pr                  → PR 생성
#
# 사용법:
#   bin/run-pipeline.sh [OPTIONS]
#
# 옵션:
#   --skip-verify    verifier 단계 스킵 (디바이스 없을 때)
#   --skip-pr        PR 생성 스킵
#   --dry-run        실행하지 않고 계획만 출력
#   --suite <name>   테스트 스위트 지정 (기본: SanitySuite)
#   --poll-interval <sec>  폴링 간격 (기본: 15초)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TASKS_DIR="$PROJECT_ROOT/.gemini/agents/tasks"
LOGS_DIR="$PROJECT_ROOT/.gemini/agents/logs"

# Defaults
SKIP_VERIFY=false
SKIP_PR=false
DRY_RUN=false
SUITE_NAME="SanitySuite"
POLL_INTERVAL=15
MAX_WAIT_PER_STAGE=1800  # 30분

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-verify)  SKIP_VERIFY=true; shift ;;
    --skip-pr)      SKIP_PR=true; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --suite)        SUITE_NAME="$2"; shift 2 ;;
    --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
    -h|--help)
      head -20 "$0" | grep '^#' | sed 's/^# *//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# ─── Shared logging ─────────────────────────────────────────────────────────
source "$SCRIPT_DIR/log-utils.sh"
_LOG_SOURCE="pipeline"

# ─── Summary log helpers ────────────────────────────────────────────────────
PIPELINE_START_EPOCH=""
SUMMARY_FILE=""
_STAGE_START_EPOCH=""

summary_header() {
  PIPELINE_START_EPOCH="$(date +%s)"
  cat >> "$SUMMARY_FILE" <<EOF
========================================
Pipeline Run: $RUN_ID
Suite: $SUITE_NAME
Started: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Options: skip-verify=$SKIP_VERIFY, skip-pr=$SKIP_PR
========================================

EOF
}

stage_start() {
  local stage_name="$1"
  _STAGE_START_EPOCH="$(date +%s)"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] STAGE_START: $stage_name" >> "$SUMMARY_FILE"
}

stage_end() {
  local stage_name="$1" status="$2"
  local duration=$(( $(date +%s) - _STAGE_START_EPOCH ))
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] STAGE_END: $stage_name | status=$status | duration=${duration}s" >> "$SUMMARY_FILE"
}

summary_task_outcome() {
  local task_id="$1" agent="$2" outcome="$3"
  echo "  TASK: $task_id | agent=$agent | outcome=$outcome" >> "$SUMMARY_FILE"
}

summary_footer() {
  local total_duration=$(( $(date +%s) - PIPELINE_START_EPOCH ))
  cat >> "$SUMMARY_FILE" <<EOF

========================================
Pipeline Finished: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Total Duration: ${total_duration}s
========================================
EOF
}

# Write task outcomes for a given agent type to the summary
write_task_outcomes() {
  local agent_type="$1"
  for task_file in "$TASKS_DIR"/task_*.json; do
    [[ -f "$task_file" ]] || continue
    local agent task_id outcome
    agent="$(python3 -c "import json; print(json.load(open('$task_file')).get('agent',''))" 2>/dev/null || echo "")"
    [[ "$agent" == "$agent_type" ]] || continue
    task_id="$(basename "$task_file" .json)"
    if [[ -f "$TASKS_DIR/${task_id}.done" ]]; then
      outcome="pass"
    elif [[ -f "$TASKS_DIR/${task_id}.failed" ]]; then
      outcome="fail"
    else
      outcome="unknown"
    fi
    summary_task_outcome "$task_id" "$agent" "$outcome"
  done
}

# Wait for all tasks of a given agent type to complete (.done files)
wait_for_tasks() {
  local agent_type="$1"
  local timeout="$2"
  local start_time
  start_time="$(date +%s)"

  log_info "Waiting for all $agent_type tasks to complete (timeout: ${timeout}s)..."

  while true; do
    local pending=0
    local running=0
    local complete=0
    local failed=0

    for task_file in "$TASKS_DIR"/task_*.json; do
      [[ -f "$task_file" ]] || continue
      local agent status task_id
      agent="$(python3 -c "import json; print(json.load(open('$task_file')).get('agent',''))" 2>/dev/null || echo "")"
      [[ "$agent" == "$agent_type" ]] || continue

      task_id="$(basename "$task_file" .json)"

      if [[ -f "$TASKS_DIR/${task_id}.done" ]]; then
        complete=$((complete + 1))
      elif [[ -f "$TASKS_DIR/${task_id}.failed" ]]; then
        # Check retry count
        local retries
        retries="$(python3 -c "import json; print(json.load(open('$TASKS_DIR/${task_id}.failed')).get('retryCount',0))" 2>/dev/null || echo 0)"
        if [[ "$retries" -ge 3 ]]; then
          failed=$((failed + 1))
        else
          pending=$((pending + 1))
        fi
      else
        status="$(python3 -c "import json; print(json.load(open('$task_file')).get('status',''))" 2>/dev/null || echo "")"
        case "$status" in
          complete) complete=$((complete + 1)) ;;
          running)  running=$((running + 1)) ;;
          pending)  pending=$((pending + 1)) ;;
        esac
      fi
    done

    log_info "  $agent_type: complete=$complete, running=$running, pending=$pending, failed=$failed"

    if [[ $running -eq 0 && $pending -eq 0 ]]; then
      log_info "All $agent_type tasks finished. ($complete complete, $failed failed)"
      return 0
    fi

    local elapsed=$(( $(date +%s) - start_time ))
    if [[ $elapsed -ge $timeout ]]; then
      log_error "Timeout waiting for $agent_type tasks ($elapsed seconds elapsed)"
      return 1
    fi

    sleep "$POLL_INTERVAL"
  done
}

# Count tasks by agent type and status
count_tasks() {
  local agent_type="$1"
  local target_status="$2"
  local count=0

  for task_file in "$TASKS_DIR"/task_*.json; do
    [[ -f "$task_file" ]] || continue
    local agent status
    agent="$(python3 -c "import json; print(json.load(open('$task_file')).get('agent',''))" 2>/dev/null || echo "")"
    status="$(python3 -c "import json; print(json.load(open('$task_file')).get('status',''))" 2>/dev/null || echo "")"
    [[ "$agent" == "$agent_type" && "$status" == "$target_status" ]] && count=$((count + 1))
  done
  echo "$count"
}

# Find the latest file matching a pattern
find_latest_file() {
  local pattern="$1"
  ls -t $pattern 2>/dev/null | head -1
}

# ─── Pipeline stages ────────────────────────────────────────────────────────

stage_discover() {
  log_info "=== Stage 1: Discover Devices ==="
  "$SCRIPT_DIR/device-pool.sh" discover

  local android_count ios_count
  android_count="$("$SCRIPT_DIR/device-pool.sh" count android)"
  ios_count="$("$SCRIPT_DIR/device-pool.sh" count ios)"

  log_info "Available devices: Android=$android_count, iOS=$ios_count"

  if [[ "$android_count" -eq 0 && "$ios_count" -eq 0 ]]; then
    if [[ "$SKIP_VERIFY" == "false" ]]; then
      log_info "No devices found. Verify stage will be skipped."
      SKIP_VERIFY=true
    fi
  fi

  ANDROID_DEVICE_COUNT="$android_count"
  IOS_DEVICE_COUNT="$ios_count"
}

stage_test_planning() {
  log_info "=== Stage 2: Test Planning ==="
  log_info "Creating tester-agent tasks for suite: $SUITE_NAME"

  # Use gemini CLI to run test-planing command
  cd "$PROJECT_ROOT"
  gemini -e base-orchestrator -y -p "/agents:test-planing" 2>&1 | tee "$RUN_DIR/pipeline_test_planning.log" || true

  local task_count
  task_count="$(count_tasks tester-agent pending)"
  log_info "Created $task_count tester-agent tasks"

  if [[ "$task_count" -eq 0 ]]; then
    log_error "No tester-agent tasks created. Check test-planing output."
    return 1
  fi
}

stage_run_tests() {
  log_info "=== Stage 3: Run Tests ==="
  local max_parallel="${ANDROID_DEVICE_COUNT:-1}"
  [[ "$max_parallel" -lt 1 ]] && max_parallel=1

  log_info "Running tester-agent tasks (max parallel: $max_parallel)"

  local launched=0
  for task_file in "$TASKS_DIR"/task_*.json; do
    [[ -f "$task_file" ]] || continue

    local agent status task_id prompt log_file
    agent="$(python3 -c "import json; print(json.load(open('$task_file')).get('agent',''))" 2>/dev/null || echo "")"
    status="$(python3 -c "import json; print(json.load(open('$task_file')).get('status',''))" 2>/dev/null || echo "")"
    [[ "$agent" == "tester-agent" && "$status" == "pending" ]] || continue

    task_id="$(python3 -c "import json; print(json.load(open('$task_file')).get('taskId',''))" 2>/dev/null)"
    prompt="$(python3 -c "import json; print(json.load(open('$task_file')).get('prompt',''))" 2>/dev/null)"
    log_file="$(python3 -c "import json; print(json.load(open('$task_file')).get('logFile',''))" 2>/dev/null)"

    # Wait if at max parallel
    while true; do
      local running
      running="$(count_tasks tester-agent running)"
      if [[ "$running" -lt "$max_parallel" ]]; then
        break
      fi
      sleep "$POLL_INTERVAL"
    done

    # Update status to running
    python3 -c "
import json
with open('$task_file') as f: d = json.load(f)
d['status'] = 'running'
with open('$task_file', 'w') as f: json.dump(d, f, ensure_ascii=False)
"

    # Launch
    log_info "Launching $task_id"
    "$SCRIPT_DIR/run-agent-with-retry.sh" "$agent" "$task_id" "$log_file" "$prompt" &

    launched=$((launched + 1))
  done

  log_info "Launched $launched tester-agent tasks"

  # Wait for all to complete
  wait_for_tasks "tester-agent" "$MAX_WAIT_PER_STAGE"
}

stage_aggregate() {
  log_info "=== Stage 4: Aggregate Results ==="
  python3 "$SCRIPT_DIR/aggregate-test-results.py" \
    -d "$LOGS_DIR" \
    -o "$RUN_DIR/aggregated_uitest_results.json"

  AGGREGATED_FILE="$RUN_DIR/aggregated_uitest_results.json"

  # Check if there are failures
  local failed_count
  failed_count="$(python3 -c "import json; print(json.load(open('$AGGREGATED_FILE')).get('failedCount', 0))" 2>/dev/null || echo 0)"

  log_info "Aggregated: $failed_count failures"

  if [[ "$failed_count" -eq 0 ]]; then
    log_info "No failures found. Pipeline complete (no fixes needed)."
    return 1  # Signal to skip remaining stages
  fi
}

stage_verify() {
  log_info "=== Stage 5: Device Verification ==="

  if [[ "$SKIP_VERIFY" == "true" ]]; then
    log_info "Verify stage skipped. Passing all failures to coder-agent."
    # Create a pass-through device_verification.json
    python3 -c "
import json

with open('$AGGREGATED_FILE') as f:
    data = json.load(f)

verification = {
    'deviceId': 'skipped',
    'projectPath': data.get('projectPath', ''),
    'verifiedFailures': data.get('failedTests', []),
    'verifiedPasses': []
}

# Add deviceResult and verificationNote to each failure
for f in verification['verifiedFailures']:
    f['deviceResult'] = 'SKIPPED'
    f['verificationNote'] = 'Device verification skipped - no device available'

output_path = '$LOGS_DIR/pipeline_device_verification.json'
with open(output_path, 'w') as f:
    json.dump(verification, f, indent=2, ensure_ascii=False)
print(f'Pass-through verification written to: {output_path}')
"
    VERIFICATION_FILE="$LOGS_DIR/pipeline_device_verification.json"
    return 0
  fi

  # Create verifier-agent task
  local task_id="task_$(date +%s)_verify"
  local now
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local verify_prompt="You are the verifier-agent. Your Task ID is $task_id. Read the uitest results file at $AGGREGATED_FILE and verify each failed test in failedTests on the real device. Follow your persona instructions and create .gemini/agents/tasks/${task_id}.done when finished."

  python3 -c "
import json
task = {
    'taskId': '$task_id',
    'status': 'pending',
    'agent': 'verifier-agent',
    'prompt': '''$verify_prompt''',
    'planFile': '.gemini/agents/plans/${task_id}_plan.md',
    'logFile': '.gemini/agents/logs/${task_id}.log',
    'createdAt': '$now'
}
with open('$TASKS_DIR/${task_id}.json', 'w') as f:
    json.dump(task, f, ensure_ascii=False)
"
  echo "# Plan for verifier-agent - Verify aggregated test failures" > "$PROJECT_ROOT/.gemini/agents/plans/${task_id}_plan.md"

  # Update to running and launch
  python3 -c "
import json
with open('$TASKS_DIR/${task_id}.json') as f: d = json.load(f)
d['status'] = 'running'
with open('$TASKS_DIR/${task_id}.json', 'w') as f: json.dump(d, f, ensure_ascii=False)
"

  "$SCRIPT_DIR/run-agent-with-retry.sh" verifier-agent "$task_id" ".gemini/agents/logs/${task_id}.log" "$verify_prompt" &

  wait_for_tasks "verifier-agent" "$MAX_WAIT_PER_STAGE"

  # Find the verification result
  VERIFICATION_FILE="$(find_latest_file "$LOGS_DIR/*_device_verification.json")"
  if [[ -z "$VERIFICATION_FILE" ]]; then
    log_error "No device_verification.json found after verifier-agent."
    return 1
  fi

  # Check verified failures count
  local verified_failures
  verified_failures="$(python3 -c "import json; print(len(json.load(open('$VERIFICATION_FILE')).get('verifiedFailures', [])))" 2>/dev/null || echo 0)"
  log_info "Verified failures: $verified_failures"

  if [[ "$verified_failures" -eq 0 ]]; then
    log_info "All failures were emulator-only issues. No fixes needed."
    return 1
  fi
}

stage_fix() {
  log_info "=== Stage 6: Fix Failures ==="

  # Use gemini CLI to run fix command
  cd "$PROJECT_ROOT"
  gemini -e base-orchestrator -y -p "/agents:fix $VERIFICATION_FILE" 2>&1 | tee "$RUN_DIR/pipeline_fix.log" || true

  # Wait for all coder-agent tasks
  wait_for_tasks "coder-agent" "$MAX_WAIT_PER_STAGE"

  local fix_count
  fix_count="$(ls "$LOGS_DIR"/*_fix_report.json 2>/dev/null | wc -l | tr -d ' ')"
  log_info "Fix reports generated: $fix_count"
}

stage_pr() {
  log_info "=== Stage 7: Create PR ==="

  if [[ "$SKIP_PR" == "true" ]]; then
    log_info "PR stage skipped."
    return 0
  fi

  cd "$PROJECT_ROOT"
  gemini -e base-orchestrator -y -p "/agents:pr" 2>&1 | tee "$RUN_DIR/pipeline_pr.log" || true

  wait_for_tasks "pr-agent" "$MAX_WAIT_PER_STAGE"

  local pr_report
  pr_report="$(find_latest_file "$LOGS_DIR/*_pr_report.json")"
  if [[ -n "$pr_report" ]]; then
    local pr_url
    pr_url="$(python3 -c "import json; print(json.load(open('$pr_report')).get('prUrl', 'N/A'))" 2>/dev/null || echo "N/A")"
    log_info "PR created: $pr_url"
  else
    log_info "PR report not found. Check logs."
  fi
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would execute:"
    log_info "  1. device-pool.sh discover"
    log_info "  2. /agents:test-planing (for $SUITE_NAME)"
    log_info "  3. run-all tester-agent (device-limited)"
    log_info "  4. aggregate-test-results.py"
    log_info "  5. /agents:verify (device-limited)"
    log_info "  6. /agents:fix"
    log_info "  7. /agents:pr"
    exit 0
  fi

  mkdir -p "$LOGS_DIR" "$TASKS_DIR"

  # Run-level log directory & cleanup
  create_run_dir "$LOGS_DIR"
  cleanup_old_runs "$LOGS_DIR"
  _LOG_FILE="$RUN_DIR/pipeline.log"
  SUMMARY_FILE="$RUN_DIR/run_summary.log"

  log_info "=========================================="
  log_info "UITest Pipeline Started"
  log_info "Suite: $SUITE_NAME"
  log_info "Skip verify: $SKIP_VERIFY"
  log_info "Skip PR: $SKIP_PR"
  log_info "Run directory: $RUN_DIR"
  log_info "=========================================="

  summary_header

  # Stage 1: Discover
  stage_start "discover"
  stage_discover
  stage_end "discover" "ok"

  # Stage 2: Test Planning
  stage_start "test-planning"
  stage_test_planning
  stage_end "test-planning" "ok"

  # Stage 3: Run Tests
  stage_start "run-tests"
  stage_run_tests
  write_task_outcomes "tester-agent"
  stage_end "run-tests" "ok"

  # Stage 4: Aggregate (returns 1 if no failures)
  stage_start "aggregate"
  if ! stage_aggregate; then
    stage_end "aggregate" "no-failures"
    log_info "Pipeline complete — no failures to process."
    summary_footer
    exit 0
  fi
  stage_end "aggregate" "ok"

  # Stage 5: Verify (returns 1 if all were emulator-only)
  stage_start "verify"
  if ! stage_verify; then
    stage_end "verify" "no-real-failures"
    log_info "Pipeline complete — no real failures after verification."
    summary_footer
    exit 0
  fi
  write_task_outcomes "verifier-agent"
  stage_end "verify" "ok"

  # Stage 6: Fix
  stage_start "fix"
  stage_fix
  write_task_outcomes "coder-agent"
  stage_end "fix" "ok"

  # Stage 7: PR
  stage_start "pr"
  stage_pr
  write_task_outcomes "pr-agent"
  stage_end "pr" "ok"

  log_info "=========================================="
  log_info "UITest Pipeline Complete"
  log_info "=========================================="

  summary_footer
}

main "$@"
