#!/usr/bin/env bash
#
# run-pipeline.sh — 전체 UITest 파이프라인 오케스트레이터
#
# 워크플로우:
#   1. discover devices    → 디바이스 풀 초기화
#   2. run-tests           → run-test-android.sh / run-test-ios.sh로 플랫폼별 테스트 실행
#   3. aggregate           → 결과 집계
#   4. verify              → verifier-agent 2차 검증 (디바이스별 병렬 실행)
#   5. fix                 → coder-agent 수정
#   6. re-test             → 수정된 클래스만 재실행
#   7. pr                  → PR 생성
#
# 사용법:
#   bin/run-pipeline.sh [OPTIONS]
#
# 옵션:
#   --skip-verify    verifier 단계 스킵 (디바이스 없을 때)
#   --skip-pr        PR 생성 스킵
#   --dry-run        실행하지 않고 계획만 출력
#   --class <name>   특정 테스트 클래스 지정 (복수 가능, TestSuite 클래스도 지정 가능)
#   --pattern <glob> 테스트 클래스 파일명 패턴 (예: *Home*)
#   --poll-interval <sec>  폴링 간격 (기본: 15초)
#   --variant <name> 빌드 variant (기본: googleBeta)
#   --module <name>  모듈명 (기본: yogiyo)
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
TEST_CLASSES=""
TEST_PATTERN=""
POLL_INTERVAL=15
MAX_WAIT_PER_STAGE=1800  # 30분
BUILD_VARIANT="googleBeta"
MODULE="yogiyo"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-verify)  SKIP_VERIFY=true; shift ;;
    --skip-pr)      SKIP_PR=true; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --class)        TEST_CLASSES="$TEST_CLASSES --class $2"; shift 2 ;;
    --pattern)      TEST_PATTERN="--pattern $2"; shift 2 ;;
    --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
    --variant)      BUILD_VARIANT="$2"; shift 2 ;;
    --module)       MODULE="$2"; shift 2 ;;
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

stage_run_tests() {
  log_info "=== Stage 2: Run Tests (Platform-aware — Android / iOS) ==="

  # 1. --class / --pattern 인자로 class_args 구성
  local class_args=()

  if [[ -n "$TEST_CLASSES" ]]; then
    # TEST_CLASSES는 "--class X --class Y" 형식
    eval "local args=($TEST_CLASSES)"
    class_args+=("${args[@]}")
  fi

  # --pattern은 run-test-android.sh가 직접 지원하지 않으므로,
  # 패턴이 지정된 경우 워크스페이스에서 매칭되는 테스트 클래스를 검색
  if [[ -n "$TEST_PATTERN" ]]; then
    local pattern_val="${TEST_PATTERN#--pattern }"
    log_info "Resolving pattern: $pattern_val"
    local workspace_dir="$PROJECT_ROOT/.gemini/agents/workspace"
    while IFS= read -r fqn; do
      [[ -n "$fqn" ]] && class_args+=("--class" "$fqn")
    done < <(python3 -c "
import os, re
pattern = '$pattern_val'
workspace = '$workspace_dir'
for root, dirs, files in os.walk(workspace):
    if 'androidTest' not in root:
        continue
    for f in files:
        if not (f.endswith('.kt') or f.endswith('.java')):
            continue
        name = os.path.splitext(f)[0]
        import fnmatch
        if not fnmatch.fnmatch(name, pattern):
            continue
        path = os.path.join(root, f)
        with open(path) as fh:
            content = fh.read()
        if '@Test' not in content and '@RunWith' not in content:
            continue
        pkg = ''
        for line in content.splitlines():
            if line.strip().startswith('package '):
                pkg = line.strip().replace('package ', '').rstrip(';').strip()
                break
        if pkg:
            print(f'{pkg}.{name}')
" 2>/dev/null)
    log_info "Pattern resolved to ${#class_args[@]} class args"
  fi

  # 2. 워크스페이스 프로젝트 디렉토리 탐색 (Android / iOS 자동 식별)
  local android_project=""
  local ios_project=""

  for dir in "$PROJECT_ROOT/.gemini/agents/workspace"/*/; do
    [[ -d "$dir" ]] || continue
    if [[ -f "$dir/build.gradle" || -f "$dir/build.gradle.kts" ]]; then
      android_project="$dir"
    fi
    if ls "$dir"/*.xcworkspace 2>/dev/null | head -1 > /dev/null || \
       ls "$dir"/*.xcodeproj 2>/dev/null | head -1 > /dev/null; then
      ios_project="$dir"
    fi
  done

  local ran_any=false

  # 3. Android 테스트 실행
  if [[ -n "$android_project" ]]; then
    android_project="${android_project%/}"
    local android_relative="${android_project#$PROJECT_ROOT/}"

    log_info "Android project: $android_relative"
    log_info "Build variant: $BUILD_VARIANT, Module: $MODULE"

    local android_exit_code=0
    (
      cd "$android_project"
      "$SCRIPT_DIR/run-test-android.sh" \
        --variant "$BUILD_VARIANT" \
        --module "$MODULE" \
        --output-dir "${RUN_DIR:-$LOGS_DIR}" \
        --project-path "$android_relative" \
        "${class_args[@]}"
    ) >> "$RUN_DIR/run-test-android.log" 2>&1 || android_exit_code=$?

    log_info "run-test-android.sh exited with code: $android_exit_code"
    ran_any=true
  fi

  # 4. iOS 테스트 실행
  if [[ -n "$ios_project" && "${IOS_DEVICE_COUNT:-0}" -gt 0 ]]; then
    ios_project="${ios_project%/}"
    local ios_relative="${ios_project#$PROJECT_ROOT/}"

    log_info "iOS project: $ios_relative"

    local ios_exit_code=0
    "$SCRIPT_DIR/run-test-ios.sh" \
      --project "$ios_project" \
      --output-dir "${RUN_DIR:-$LOGS_DIR}" \
      --project-path "$ios_relative" \
      "${class_args[@]}" \
      >> "$RUN_DIR/run-test-ios.log" 2>&1 || ios_exit_code=$?

    log_info "run-test-ios.sh exited with code: $ios_exit_code"
    ran_any=true
  fi

  if [[ "$ran_any" == "false" ]]; then
    log_error "No project found in .gemini/agents/workspace/"
    return 1
  fi

  log_info "Test execution complete"
}

stage_aggregate() {
  log_info "=== Stage 3: Check Results ==="

  AGGREGATED_FILE="$RUN_DIR/all_uitest_results.json"

  if [[ ! -f "$AGGREGATED_FILE" ]]; then
    log_error "Result file not found: $AGGREGATED_FILE"
    return 1
  fi

  # Check if there are failures
  local failed_count
  failed_count="$(python3 -c "import json; print(json.load(open('$AGGREGATED_FILE')).get('failedCount', 0))" 2>/dev/null || echo 0)"

  log_info "Result: $failed_count failures"

  if [[ "$failed_count" -eq 0 ]]; then
    log_info "No failures found. Pipeline complete (no fixes needed)."
    return 1  # Signal to skip remaining stages
  fi
}

stage_verify() {
  log_info "=== Stage 4: Device Verification (Parallel) ==="

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

  # 1. 가용 디바이스 수 및 실패 건수 조회
  local idle_count
  idle_count="$("$SCRIPT_DIR/device-pool.sh" count android)"
  local failed_count
  failed_count="$(python3 -c "import json; print(len(json.load(open('$AGGREGATED_FILE')).get('failedTests', [])))" 2>/dev/null || echo 0)"

  local num_agents
  num_agents=$((idle_count < failed_count ? idle_count : failed_count))
  [[ "$num_agents" -lt 1 ]] && num_agents=1

  log_info "Idle devices: $idle_count, Failed tests: $failed_count -> Launching $num_agents verifier-agent(s)"

  # 2. 실패 테스트를 shard로 분할
  python3 "$SCRIPT_DIR/split-failures.py" \
    --input "$AGGREGATED_FILE" \
    --num-shards "$num_agents" \
    --output-dir "$RUN_DIR" \
    2>&1 | while IFS= read -r line; do log_info "  $line"; done

  # 3. shard별 verifier-agent 태스크 생성 및 병렬 실행
  local base_ts
  base_ts="$(date +%s)"
  local now
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  for i in $(seq 0 $((num_agents - 1))); do
    local task_id="task_${base_ts}_verify_${i}"
    local shard_file="$RUN_DIR/verify_shard_${i}_uitest_results.json"
    local verify_prompt="You are the verifier-agent. Your Task ID is $task_id. Read the uitest results file at $shard_file and verify each failed test in failedTests on the real device. Follow your persona instructions and create .gemini/agents/tasks/${task_id}.done when finished."

    python3 -c "
import json
task = {
    'taskId': '$task_id',
    'status': 'running',
    'agent': 'verifier-agent',
    'prompt': '''$verify_prompt''',
    'planFile': '.gemini/agents/plans/${task_id}_plan.md',
    'logFile': '.gemini/agents/logs/${task_id}.log',
    'createdAt': '$now'
}
with open('$TASKS_DIR/${task_id}.json', 'w') as f:
    json.dump(task, f, ensure_ascii=False)
"
    echo "# Plan for verifier-agent shard $i - Verify test failures" > "$PROJECT_ROOT/.gemini/agents/plans/${task_id}_plan.md"

    "$SCRIPT_DIR/run-agent-with-retry.sh" verifier-agent "$task_id" ".gemini/agents/logs/${task_id}.log" "$verify_prompt" &

    log_info "Launched verifier-agent shard $i: $task_id"
  done

  # 4. 모든 verifier-agent 태스크 완료 대기
  wait_for_tasks "verifier-agent" "$MAX_WAIT_PER_STAGE"

  # 5. 결과 병합
  python3 "$SCRIPT_DIR/merge-verification-results.py" \
    --dir "$LOGS_DIR" \
    --output "$LOGS_DIR/pipeline_device_verification.json" \
    --aggregated "$AGGREGATED_FILE" \
    2>&1 | while IFS= read -r line; do log_info "  $line"; done

  VERIFICATION_FILE="$LOGS_DIR/pipeline_device_verification.json"

  if [[ ! -f "$VERIFICATION_FILE" ]]; then
    log_error "No pipeline_device_verification.json found after merge."
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
  log_info "=== Stage 5: Fix Failures ==="

  cd "$PROJECT_ROOT"

  # VERIFICATION_FILE에서 verifiedFailures를 읽어 className별로 그룹화 → coder-agent 태스크 생성
  local base_ts
  base_ts="$(date +%s)"
  local now
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  local task_count=0
  python3 -c "
import json, os

vf = json.load(open('$VERIFICATION_FILE'))
failures = vf.get('verifiedFailures', [])
if not failures:
    print('NO_FAILURES')
    exit(0)

# className별 그룹화
by_class = {}
for f in failures:
    cls = f.get('className', 'unknown')
    by_class.setdefault(cls, []).append(f)

base_ts = $base_ts
now = '$now'
tasks_dir = '$TASKS_DIR'
plans_dir = '$PROJECT_ROOT/.gemini/agents/plans'
os.makedirs(tasks_dir, exist_ok=True)
os.makedirs(plans_dir, exist_ok=True)

for i, (cls, tests) in enumerate(by_class.items()):
    task_id = f'task_{base_ts}_fix_{i}'
    simple_name = cls.rsplit('.', 1)[-1] if '.' in cls else cls
    test_names = ', '.join(t.get('testName', '?') for t in tests)
    prompt = (
        f'You are the coder-agent. Your Task ID is {task_id}. '
        f'Fix the verified test failures for class {cls}. '
        f'Failed tests: {test_names}. '
        f'Verification file: $VERIFICATION_FILE. '
        f'Read the test source and production code, analyze failure patterns, apply targeted fixes, '
        f'run compile check, commit changes, and write fix report to .gemini/agents/logs/{task_id}_fix_report.json. '
        f'Create .gemini/agents/tasks/{task_id}.done when finished.'
    )
    task = {
        'taskId': task_id,
        'status': 'pending',
        'agent': 'coder-agent',
        'prompt': prompt,
        'planFile': f'.gemini/agents/plans/{task_id}_plan.md',
        'logFile': f'.gemini/agents/logs/{task_id}.log',
        'createdAt': now,
    }
    with open(f'{tasks_dir}/{task_id}.json', 'w') as f:
        json.dump(task, f, ensure_ascii=False)
    with open(f'{plans_dir}/{task_id}_plan.md', 'w') as f:
        f.write(f'# Plan for coder-agent - Fix {simple_name}\n\nClass: \`{cls}\`\nFailed tests: {test_names}\n')
    print(f'TASK:{task_id}:{cls}')
" 2>&1 | while IFS= read -r line; do
    if [[ "$line" == "NO_FAILURES" ]]; then
      log_info "No verified failures to fix."
      return 0
    elif [[ "$line" == TASK:* ]]; then
      local tid cls_name
      tid="$(echo "$line" | cut -d: -f2)"
      cls_name="$(echo "$line" | cut -d: -f3)"
      log_info "Created fix task: $tid ($cls_name)"

      # run-agent-with-retry.sh로 백그라운드 실행
      local fix_prompt
      fix_prompt="$(python3 -c "import json; print(json.load(open('$TASKS_DIR/${tid}.json')).get('prompt',''))" 2>/dev/null)"
      "$SCRIPT_DIR/run-agent-with-retry.sh" coder-agent "$tid" ".gemini/agents/logs/${tid}.log" "$fix_prompt" &
      task_count=$((task_count + 1))
    fi
  done

  if [[ $task_count -gt 0 ]]; then
    log_info "Launched $task_count coder-agent task(s)"
    wait_for_tasks "coder-agent" "$MAX_WAIT_PER_STAGE"
  fi

  local fix_count
  fix_count="$(ls "$LOGS_DIR"/*_fix_report.json 2>/dev/null | wc -l | tr -d ' ')"
  log_info "Fix reports generated: $fix_count"
}

stage_pr() {
  log_info "=== Stage 7: Create PR ==="
  # (Stage 6: Re-test는 pipeline.toml에서 처리)

  if [[ "$SKIP_PR" == "true" ]]; then
    log_info "PR stage skipped."
    return 0
  fi

  cd "$PROJECT_ROOT"

  # pr-agent 태스크 직접 생성 후 run-agent-with-retry.sh로 실행
  local task_id="task_$(date +%s)_pr"
  local now
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  # fix_report 파일들 수집
  local fix_reports
  fix_reports="$(ls "$LOGS_DIR"/*_fix_report.json 2>/dev/null | tr '\n' ', ' | sed 's/,$//')"

  local pr_prompt="You are the pr-agent. Your Task ID is $task_id. Collect all fix reports from: $fix_reports. Create a feature branch fix/uitest-$(date +%Y%m%d), cherry-pick commits if needed, push to remote, and open a GitHub PR via gh CLI. Write PR report to .gemini/agents/logs/${task_id}_pr_report.json. Create .gemini/agents/tasks/${task_id}.done when finished."

  python3 -c "
import json
task = {
    'taskId': '$task_id',
    'status': 'pending',
    'agent': 'pr-agent',
    'prompt': '''$pr_prompt''',
    'planFile': '.gemini/agents/plans/${task_id}_plan.md',
    'logFile': '.gemini/agents/logs/${task_id}.log',
    'createdAt': '$now'
}
with open('$TASKS_DIR/${task_id}.json', 'w') as f:
    json.dump(task, f, ensure_ascii=False)
"
  echo "# Plan for pr-agent - Create PR for test fixes" > "$PROJECT_ROOT/.gemini/agents/plans/${task_id}_plan.md"

  log_info "Created PR task: $task_id"

  "$SCRIPT_DIR/run-agent-with-retry.sh" pr-agent "$task_id" ".gemini/agents/logs/${task_id}.log" "$pr_prompt" &

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
    log_info "  2. run-test-android.sh --variant $BUILD_VARIANT --module $MODULE / run-test-ios.sh (platform-aware)"
    log_info "  3. check all_uitest_results.json"
    log_info "  4. /agents:verify (device-limited, queue draining)"
    log_info "  5. /agents:fix"
    log_info "  6. re-test (수정된 클래스만 재실행)"
    log_info "  7. /agents:pr"
    exit 0
  fi

  mkdir -p "$LOGS_DIR" "$TASKS_DIR"

  # 이전 실행의 잔여 태스크 자동 정리
  log_info "Cleaning up previous pipeline tasks..."
  "$SCRIPT_DIR/reset-tasks.sh" --clean 2>&1 | while IFS= read -r line; do log_info "  $line"; done || true

  # Run-level log directory & cleanup
  create_run_dir "$LOGS_DIR"
  cleanup_old_runs "$LOGS_DIR"
  _LOG_FILE="$RUN_DIR/pipeline.log"
  SUMMARY_FILE="$RUN_DIR/run_summary.log"

  log_info "=========================================="
  log_info "UITest Pipeline Started"
  log_info "Skip verify: $SKIP_VERIFY"
  log_info "Skip PR: $SKIP_PR"
  log_info "Run directory: $RUN_DIR"
  log_info "=========================================="

  summary_header

  # Stage 1: Discover
  stage_start "discover"
  stage_discover
  stage_end "discover" "ok"

  # Stage 2: Run Tests (directly, no tester-agent tasks)
  stage_start "run-tests"
  stage_run_tests
  stage_end "run-tests" "ok"

  # Stage 3: Aggregate (returns 1 if no failures)
  stage_start "aggregate"
  if ! stage_aggregate; then
    stage_end "aggregate" "no-failures"
    log_info "Pipeline complete — no failures to process."
    summary_footer
    exit 0
  fi
  stage_end "aggregate" "ok"

  # Stage 4: Verify (returns 1 if all were emulator-only)
  stage_start "verify"
  if ! stage_verify; then
    stage_end "verify" "no-real-failures"
    log_info "Pipeline complete — no real failures after verification."
    summary_footer
    exit 0
  fi
  write_task_outcomes "verifier-agent"
  stage_end "verify" "ok"

  # Stage 5: Fix
  stage_start "fix"
  stage_fix
  write_task_outcomes "coder-agent"
  stage_end "fix" "ok"

  # Stage 6: Re-test — pipeline.toml에서 처리 (run-pipeline.sh에서는 미구현)

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
