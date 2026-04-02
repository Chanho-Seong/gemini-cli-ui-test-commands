#!/usr/bin/env bash
#
# run-pipeline.sh — 전체 UITest 파이프라인 오케스트레이터
#
# 워크플로우:
#   1. discover devices    → 디바이스 풀 초기화
#   2. create-test-tasks   → tester-agent 태스크 생성
#   3. run-all(tester)     → run-test-android.sh로 빌드 1회 + 디바이스 샤딩 실행
#   4. aggregate           → 결과 집계
#   5. verify              → verifier-agent 2차 검증 (디바이스별 병렬 실행)
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
#   --class <name>   특정 테스트 클래스 지정 (복수 가능)
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
SUITE_NAME="SanitySuite"
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
    --suite)        SUITE_NAME="$2"; shift 2 ;;
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

  # Build create-test-tasks.py arguments: --class/--pattern override --suite
  local plan_args="--suite $SUITE_NAME"
  if [[ -n "$TEST_CLASSES" ]]; then
    plan_args="$TEST_CLASSES"
  fi
  if [[ -n "$TEST_PATTERN" ]]; then
    plan_args="$TEST_PATTERN"
  fi

  # Gemini API 호출 없이 Python 스크립트로 직접 태스크 생성
  cd "$PROJECT_ROOT"
  python3 "$SCRIPT_DIR/create-test-tasks.py" $plan_args 2>&1 | tee "$RUN_DIR/pipeline_test_planning.log" || true

  local task_count
  task_count="$(count_tasks tester-agent pending)"
  log_info "Created $task_count tester-agent tasks"

  if [[ "$task_count" -eq 0 ]]; then
    log_error "No tester-agent tasks created. Check create-test-tasks.py output."
    return 1
  fi
}

stage_run_tests() {
  log_info "=== Stage 3: Run Tests (Direct — build once, shard across devices) ==="

  # 1. 모든 tester-agent 태스크에서 testClassFqn 수집
  local class_args=()
  local task_ids=()
  local task_files_map=()

  for task_file in "$TASKS_DIR"/task_*.json; do
    [[ -f "$task_file" ]] || continue

    local agent status task_id test_class_fqn
    agent="$(python3 -c "import json; print(json.load(open('$task_file')).get('agent',''))" 2>/dev/null || echo "")"
    status="$(python3 -c "import json; print(json.load(open('$task_file')).get('status',''))" 2>/dev/null || echo "")"
    [[ "$agent" == "tester-agent" && "$status" == "pending" ]] || continue

    task_id="$(python3 -c "import json; print(json.load(open('$task_file')).get('taskId',''))" 2>/dev/null)"

    # testClassFqn 필드 우선, 없으면 prompt에서 추출
    test_class_fqn="$(python3 -c "
import json, re
d = json.load(open('$task_file'))
fqn = d.get('testClassFqn', '')
if not fqn:
    m = re.search(r'class\s+([\w.]+)', d.get('prompt', ''))
    fqn = m.group(1) if m else ''
print(fqn)
" 2>/dev/null)"

    if [[ -z "$test_class_fqn" ]]; then
      log_error "Cannot extract test class FQN from task $task_id, skipping"
      continue
    fi

    class_args+=("--class" "$test_class_fqn")
    task_ids+=("$task_id")
    task_files_map+=("$task_file")

    # 상태를 running으로 업데이트
    python3 -c "
import json
with open('$task_file') as f: d = json.load(f)
d['status'] = 'running'
with open('$task_file', 'w') as f: json.dump(d, f, ensure_ascii=False)
"
  done

  if [[ ${#class_args[@]} -eq 0 ]]; then
    log_error "No test classes found in tester-agent tasks"
    return 1
  fi

  log_info "Collected ${#task_ids[@]} test class(es) for execution"
  log_info "Build variant: $BUILD_VARIANT, Module: $MODULE"

  # 2. 워크스페이스 프로젝트 디렉토리 탐색
  local workspace_project=""
  for dir in "$PROJECT_ROOT/.gemini/agents/workspace"/*/; do
    if [[ -f "$dir/build.gradle" || -f "$dir/build.gradle.kts" ]]; then
      workspace_project="$dir"
      break
    fi
  done

  if [[ -z "$workspace_project" ]]; then
    log_error "No Android project found in .gemini/agents/workspace/"
    return 1
  fi
  workspace_project="${workspace_project%/}"
  local relative_project="${workspace_project#$PROJECT_ROOT/}"

  log_info "Project: $relative_project"

  # 3. run-test-android.sh 단일 호출 (빌드 1회 + 디바이스 샤딩)
  local test_exit_code=0
  (
    cd "$workspace_project"
    "$SCRIPT_DIR/run-test-android.sh" \
      --variant "$BUILD_VARIANT" \
      --module "$MODULE" \
      "${class_args[@]}"
  ) >> "$RUN_DIR/run-test-android.log" 2>&1 || test_exit_code=$?

  log_info "run-test-android.sh exited with code: $test_exit_code"

  # 4. shard 결과를 per-task JSON으로 파싱
  local shard_dir="$workspace_project/test_results"
  python3 "$SCRIPT_DIR/parse-am-instrument-results.py" \
    --shard-dir "$shard_dir" \
    --tasks-dir "$TASKS_DIR" \
    --output-dir "${RUN_DIR:-$LOGS_DIR}" \
    --project-path "$relative_project" \
    --module "$MODULE" \
    >> "$RUN_DIR/parse-results.log" 2>&1 || {
      log_error "Failed to parse am instrument results"
    }

  # 5. 태스크별 .done 생성 및 status 업데이트
  for i in "${!task_ids[@]}"; do
    local tid="${task_ids[$i]}"
    local tfile="${task_files_map[$i]}"

    touch "$TASKS_DIR/${tid}.done"

    # 결과 JSON에서 failedCount 확인하여 status 결정
    local result_file="${RUN_DIR:-$LOGS_DIR}/${tid}_uitest_results.json"
    local new_status="complete"
    if [[ -f "$result_file" ]]; then
      local fc
      fc="$(python3 -c "import json; print(json.load(open('$result_file')).get('failedCount',0))" 2>/dev/null || echo 0)"
      [[ "$fc" -gt 0 ]] && new_status="failed"
    fi

    python3 -c "
import json
with open('$tfile') as f: d = json.load(f)
d['status'] = '$new_status'
with open('$tfile', 'w') as f: json.dump(d, f, ensure_ascii=False)
" 2>/dev/null || true
  done

  log_info "All ${#task_ids[@]} test tasks completed (run-test-android.sh exit: $test_exit_code)"
}

stage_aggregate() {
  log_info "=== Stage 4: Aggregate Results ==="
  python3 "$SCRIPT_DIR/aggregate-test-results.py" \
    -d "${RUN_DIR:-$LOGS_DIR}" \
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
  log_info "=== Stage 5: Device Verification (Parallel) ==="

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
  log_info "=== Stage 6: Fix Failures ==="

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
    local dry_plan_args="--suite $SUITE_NAME"
    [[ -n "$TEST_CLASSES" ]] && dry_plan_args="$TEST_CLASSES"
    [[ -n "$TEST_PATTERN" ]] && dry_plan_args="$TEST_PATTERN"
    log_info "  2. create-test-tasks.py $dry_plan_args"
    log_info "  3. run-test-android.sh --variant $BUILD_VARIANT --module $MODULE (build once, shard across devices)"
    log_info "  4. aggregate-test-results.py"
    log_info "  5. /agents:verify (device-limited)"
    log_info "  6. /agents:fix"
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
