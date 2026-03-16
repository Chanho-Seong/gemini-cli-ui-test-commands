#!/usr/bin/env bash
#
# bin/test-fix-pipeline.sh
#
# End-to-end test script for the UI test fix pipeline.
# Tests: /agents:fix → coder-agent → /agents:pr → pr-agent
#
# Usage:
#   bin/test-fix-pipeline.sh [--unit | --integration | --all]
#
#   --unit        : Run unit tests only (validate JSON structure, file creation)
#   --integration : Run integration tests (spawn real agents with mock data)
#   --all         : Run all tests (default)
#
# Prerequisites for integration tests:
#   - gemini CLI installed and authenticated
#   - A git repo in .gemini/agents/workspace/ (or mock one is created)
#   - gh CLI installed and authenticated (for pr-agent test only)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0
SKIP=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

MODE="${1:---all}"

pass() { echo -e "${GREEN}  PASS${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}  FAIL${NC} $1"; FAIL=$((FAIL+1)); }
skip() { echo -e "${YELLOW}  SKIP${NC} $1"; SKIP=$((SKIP+1)); }

section() { echo ""; echo "=== $1 ==="; }

# ─────────────────────────────────────────
# Helper: create mock device_verification.json
# ─────────────────────────────────────────
create_mock_verification() {
  local out="$1"
  mkdir -p "$(dirname "$out")"
  python3 -c "
import json
data = {
  'deviceId': 'emulator-5554',
  'projectPath': '.gemini/agents/workspace/MockProject',
  'verifiedFailures': [
    {
      'className': 'com.example.HomeViewTest',
      'testName': 'testHomeDisplay',
      'errorMessage': 'No views in hierarchy found matching: with id: com.example:id/btn_wrong',
      'stackTrace': 'androidx.test.espresso.NoMatchingViewException: No views in hierarchy found\n\tat com.example.HomeViewTest.testHomeDisplay(HomeViewTest.kt:42)',
      'testFilePath': 'app/src/androidTest/java/com/example/HomeViewTest.kt',
      'deviceResult': 'FAILED',
      'verificationNote': 'Real device also failed'
    },
    {
      'className': 'com.example.CartViewTest',
      'testName': 'testCartItemCount',
      'errorMessage': 'Expected: is <\"3\"> but: was <\"2\">',
      'stackTrace': 'junit.framework.AssertionFailedError: Expected: is <\"3\"> but: was <\"2\">\n\tat com.example.CartViewTest.testCartItemCount(CartViewTest.kt:67)',
      'testFilePath': 'app/src/androidTest/java/com/example/CartViewTest.kt',
      'deviceResult': 'FAILED',
      'verificationNote': 'Real device also failed'
    },
    {
      'className': 'com.example.HomeViewTest',
      'testName': 'testHomeNavigation',
      'errorMessage': 'No views in hierarchy found matching: with id: com.example:id/nav_wrong',
      'stackTrace': 'androidx.test.espresso.NoMatchingViewException\n\tat com.example.HomeViewTest.testHomeNavigation(HomeViewTest.kt:58)',
      'testFilePath': 'app/src/androidTest/java/com/example/HomeViewTest.kt',
      'deviceResult': 'FAILED',
      'verificationNote': 'Real device also failed'
    }
  ],
  'verifiedPasses': [
    {
      'className': 'com.example.LoginViewTest',
      'testName': 'testLoginSuccess',
      'deviceResult': 'PASSED',
      'verificationNote': 'Emulator-only issue, passed on real device'
    }
  ]
}
print(json.dumps(data, indent=2))
" > "$out"
}

# ─────────────────────────────────────────
# Helper: create mock fix report
# ─────────────────────────────────────────
create_mock_fix_report() {
  local task_id="$1"
  local out=".gemini/agents/logs/${task_id}_fix_report.json"
  mkdir -p "$(dirname "$out")"
  python3 -c "
import json
data = {
  'taskId': '$task_id',
  'projectPath': '.gemini/agents/workspace/MockProject',
  'className': 'com.example.HomeViewTest',
  'status': 'completed',
  'fixedTests': [
    {
      'testName': 'testHomeDisplay',
      'rootCause': 'Wrong resource ID: btn_wrong should be btn_confirm',
      'fixApplied': 'Updated withId(R.id.btn_wrong) to withId(R.id.btn_confirm)',
      'commitHash': 'abc1234'
    }
  ],
  'filesModified': ['app/src/androidTest/java/com/example/HomeViewTest.kt']
}
print(json.dumps(data, indent=2))
" > "$out"
  echo "$out"
}

# ─────────────────────────────────────────
# UNIT TESTS: /agents:fix prerequisite validation
# ─────────────────────────────────────────
test_fix_command_files_exist() {
  section "Unit: fix command file structure"

  local fix_cmd="$PROJECT_ROOT/.gemini/commands/agents/fix.toml"
  if [[ -f "$fix_cmd" ]]; then
    pass "fix.toml exists"
  else
    fail "fix.toml missing at $fix_cmd"
  fi

  # Check required fields in fix.toml
  if grep -q "description" "$fix_cmd" && grep -q "prompt" "$fix_cmd"; then
    pass "fix.toml has description and prompt fields"
  else
    fail "fix.toml missing required fields"
  fi

  if grep -q "verifiedFailures" "$fix_cmd"; then
    pass "fix.toml references verifiedFailures"
  else
    fail "fix.toml does not reference verifiedFailures"
  fi

  if grep -q "coder-agent" "$fix_cmd"; then
    pass "fix.toml targets coder-agent"
  else
    fail "fix.toml does not target coder-agent"
  fi
}

test_coder_agent_persona() {
  section "Unit: coder-agent persona"

  local persona="$PROJECT_ROOT/.gemini/extensions/coder-agent/coder-agent-persona.md"
  if [[ -f "$persona" ]]; then
    pass "coder-agent-persona.md exists"
  else
    fail "coder-agent-persona.md missing"
    return
  fi

  local checks=(
    "STEP 1"
    "STEP 2"
    "STEP 3"
    "STEP 4"
    "STEP 5"
    "STEP 6"
    "STEP 7"
    "Analyze Failure"
    "Compile Check"
    "fix_report"
    "git commit"
    "CODER-LOG"
    "needs_review"
  )
  for check in "${checks[@]}"; do
    if grep -q "$check" "$persona"; then
      pass "persona contains: $check"
    else
      fail "persona missing: $check"
    fi
  done
}

test_pr_agent_extension() {
  section "Unit: pr-agent extension"

  local ext_json="$PROJECT_ROOT/.gemini/extensions/pr-agent/gemini-extension.json"
  local persona="$PROJECT_ROOT/.gemini/extensions/pr-agent/pr-agent-persona.md"

  if [[ -f "$ext_json" ]]; then
    pass "pr-agent gemini-extension.json exists"
    local name
    name=$(python3 -c "import json,sys; d=json.load(open('$ext_json')); print(d.get('name',''))" 2>/dev/null || echo "")
    if [[ "$name" == "pr-agent" ]]; then
      pass "extension name is pr-agent"
    else
      fail "extension name is not pr-agent (got: $name)"
    fi
  else
    fail "pr-agent gemini-extension.json missing"
  fi

  if [[ -f "$persona" ]]; then
    pass "pr-agent-persona.md exists"
  else
    fail "pr-agent-persona.md missing"
    return
  fi

  local checks=(
    "STEP 1"
    "STEP 2"
    "STEP 3"
    "STEP 4"
    "STEP 5"
    "STEP 6"
    "STEP 7"
    "STEP 8"
    "fix_report"
    "gh pr create"
    "PR-LOG"
    "pr_report"
    "baseBranch"
  )
  for check in "${checks[@]}"; do
    if grep -q "$check" "$persona"; then
      pass "pr-agent persona contains: $check"
    else
      fail "pr-agent persona missing: $check"
    fi
  done
}

test_pr_command_file() {
  section "Unit: /agents:pr command"

  local pr_cmd="$PROJECT_ROOT/.gemini/commands/agents/pr.toml"
  if [[ -f "$pr_cmd" ]]; then
    pass "pr.toml exists"
  else
    fail "pr.toml missing"
    return
  fi

  if grep -q "pr-agent" "$pr_cmd"; then
    pass "pr.toml targets pr-agent"
  else
    fail "pr.toml does not target pr-agent"
  fi

  if grep -q "fix_report" "$pr_cmd"; then
    pass "pr.toml references fix reports"
  else
    fail "pr.toml does not reference fix reports"
  fi
}

test_verifier_agent_stacktrace() {
  section "Unit: verifier-agent stackTrace passthrough"

  local persona="$PROJECT_ROOT/.gemini/extensions/verifier-agent/verifier-agent-persona.md"
  if grep -q "stackTrace" "$persona"; then
    pass "verifier-agent persona includes stackTrace in verifiedFailures"
  else
    fail "verifier-agent persona does not mention stackTrace in verifiedFailures"
  fi
}

# ─────────────────────────────────────────
# UNIT TESTS: JSON structure validation
# ─────────────────────────────────────────
test_mock_verification_json() {
  section "Unit: mock device_verification.json structure"

  local mock_path="/tmp/test_mock_verification_$$.json"
  create_mock_verification "$mock_path"

  if python3 -c "
import json, sys
with open('$mock_path') as f:
    d = json.load(f)
assert 'verifiedFailures' in d, 'missing verifiedFailures'
assert len(d['verifiedFailures']) == 3, 'expected 3 failures'
assert 'className' in d['verifiedFailures'][0], 'missing className'
assert 'testFilePath' in d['verifiedFailures'][0], 'missing testFilePath'
assert 'stackTrace' in d['verifiedFailures'][0], 'missing stackTrace'
assert 'errorMessage' in d['verifiedFailures'][0], 'missing errorMessage'
print('OK')
" 2>&1 | grep -q "OK"; then
    pass "mock verification JSON structure is valid"
  else
    fail "mock verification JSON structure is invalid"
  fi

  # Test grouping by className: should produce 2 unique classes
  local unique_classes
  unique_classes=$(python3 -c "
import json
with open('$mock_path') as f:
    d = json.load(f)
classes = set(t['className'] for t in d['verifiedFailures'])
print(len(classes))
")
  if [[ "$unique_classes" == "2" ]]; then
    pass "mock data has 2 unique className groups (correct for parallel tasks)"
  else
    fail "expected 2 unique classes, got $unique_classes"
  fi

  rm -f "$mock_path"
}

# ─────────────────────────────────────────
# INTEGRATION TESTS: Spawn real agents
# ─────────────────────────────────────────
test_integration_fix_task_creation() {
  section "Integration: /agents:fix task creation (via gemini CLI)"

  if ! command -v gemini &>/dev/null; then
    skip "gemini CLI not found — skipping integration test"
    return
  fi

  local mock_path="$PROJECT_ROOT/.gemini/agents/logs/test_mock_verification_$$.json"
  create_mock_verification "$mock_path"

  echo "  Running: gemini -p '/agents:fix $mock_path' ..."
  local output
  output=$(cd "$PROJECT_ROOT" && timeout 120 gemini -e base-orchestrator -y -p "/agents:fix $mock_path" 2>&1 || true)

  # Check that task files were created
  local task_files
  task_files=$(ls "$PROJECT_ROOT/.gemini/agents/tasks/"*_fix_*.json 2>/dev/null | wc -l | tr -d ' ')

  if [[ "$task_files" -ge 2 ]]; then
    pass "fix command created $task_files task files (expected >= 2)"
  else
    fail "fix command created only $task_files task files (expected >= 2)"
    echo "  Output: $output" | head -20
  fi

  # Validate task JSON structure
  for task_file in "$PROJECT_ROOT/.gemini/agents/tasks/"*_fix_*.json; do
    if python3 -c "
import json
with open('$task_file') as f:
    d = json.load(f)
assert d.get('agent') == 'coder-agent', 'agent must be coder-agent'
assert 'taskId' in d
assert 'prompt' in d
assert 'className' in d['prompt'] or 'class' in d['prompt'].lower()
print('OK')
" 2>&1 | grep -q "OK"; then
      pass "task file valid: $(basename "$task_file")"
    else
      fail "task file invalid: $(basename "$task_file")"
    fi
  done

  rm -f "$mock_path"
}

test_integration_coder_agent_with_mock_task() {
  section "Integration: coder-agent with mock task (no actual test repo)"

  if ! command -v gemini &>/dev/null; then
    skip "gemini CLI not found — skipping integration test"
    return
  fi

  local ts
  ts=$(date +%s)
  local task_id="task_${ts}_fix_test"
  local task_file="$PROJECT_ROOT/.gemini/agents/tasks/${task_id}.json"
  local plan_file="$PROJECT_ROOT/.gemini/agents/plans/${task_id}_plan.md"
  local log_file="$PROJECT_ROOT/.gemini/agents/logs/${task_id}.log"

  # Write a minimal mock task
  python3 -c "
import json
prompt = (
  'You are the coder-agent. Your Task ID is $task_id. '
  'Fix failing UI tests in the project at .gemini/agents/workspace/MockProject (platform: android). '
  'Test class: com.example.HomeViewTest. '
  'Test file (relative to project root): app/src/androidTest/java/com/example/HomeViewTest.kt. '
  'Failing tests: [{\"testName\":\"testHomeDisplay\",\"errorMessage\":\"No views found matching: R.id.btn_wrong\",\"verificationNote\":\"Real device failed\"}]. '
  'Since this is a test run, the project may not exist. '
  'If the project or test file does not exist, write a fix report with status: needs_review, '
  'explain that the project was not found, create .gemini/agents/tasks/$task_id.done.'
)
d = {
  'taskId': '$task_id',
  'status': 'pending',
  'agent': 'coder-agent',
  'prompt': prompt,
  'planFile': '$plan_file',
  'logFile': '$log_file',
  'createdAt': '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
}
print(json.dumps(d))
" > "$task_file"
  echo "# Plan for coder-agent test" > "$plan_file"

  echo "  Running coder-agent for task $task_id ..."
  timeout 180 "$PROJECT_ROOT/bin/run-agent-with-retry.sh" coder-agent "$task_id" "$log_file" \
    "$(python3 -c "import json; d=json.load(open('$task_file')); print(d['prompt'])")" || true

  # Check sentinel file created
  if [[ -f "$PROJECT_ROOT/.gemini/agents/tasks/${task_id}.done" ]]; then
    pass "coder-agent created .done sentinel file"
  else
    fail "coder-agent did NOT create .done sentinel file"
    echo "  Last 20 lines of log:"
    tail -20 "$log_file" 2>/dev/null || echo "  (no log)"
  fi

  # Check fix report created
  local fix_report="$PROJECT_ROOT/.gemini/agents/logs/${task_id}_fix_report.json"
  if [[ -f "$fix_report" ]]; then
    pass "coder-agent created fix report: $(basename "$fix_report")"
    if python3 -c "import json; d=json.load(open('$fix_report')); assert 'status' in d and 'taskId' in d; print('OK')" 2>&1 | grep -q "OK"; then
      pass "fix report JSON structure is valid"
    else
      fail "fix report JSON structure is invalid"
    fi
  else
    fail "coder-agent did NOT create fix report"
  fi
}

test_integration_pr_agent_prereqs() {
  section "Integration: pr-agent prerequisites check"

  if ! command -v gemini &>/dev/null; then
    skip "gemini CLI not found"
    return
  fi

  if ! command -v gh &>/dev/null; then
    skip "GitHub CLI (gh) not found — pr-agent integration test skipped"
    return
  fi

  if ! gh auth status &>/dev/null; then
    skip "GitHub CLI not authenticated — run: gh auth login"
    return
  fi

  pass "gemini CLI found"
  pass "GitHub CLI (gh) found and authenticated"
  echo "  Note: Full pr-agent integration test requires a real git repo with remote."
  echo "  To run: create fix reports then run /agents:pr manually."
  skip "Full pr-agent integration test skipped (requires real project with remote)"
}

# ─────────────────────────────────────────
# UNIT TESTS: Script integrity
# ─────────────────────────────────────────
test_run_agent_script_supports_pr_agent() {
  section "Unit: run-agent-with-retry.sh supports pr-agent"

  local script="$PROJECT_ROOT/bin/run-agent-with-retry.sh"
  if [[ -x "$script" ]]; then
    pass "run-agent-with-retry.sh is executable"
  else
    fail "run-agent-with-retry.sh is not executable"
  fi

  # pr-agent should use pro model (non-tester branch)
  # The script uses: if [[ "$AGENT" == "tester-agent" ]] → flash; else → pro
  # So pr-agent will correctly use pro model. Verify the logic is present.
  if grep -q 'tester-agent' "$script" && grep -q 'pro' "$script"; then
    pass "run-agent-with-retry.sh has model selection logic covering pr-agent"
  else
    fail "run-agent-with-retry.sh missing model selection logic"
  fi
}

# ─────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────
cd "$PROJECT_ROOT"

echo "======================================"
echo " UI Test Fix Pipeline — Test Suite"
echo " Mode: $MODE"
echo "======================================"

case "$MODE" in
  --unit|--all)
    test_fix_command_files_exist
    test_coder_agent_persona
    test_pr_agent_extension
    test_pr_command_file
    test_verifier_agent_stacktrace
    test_mock_verification_json
    test_run_agent_script_supports_pr_agent
    ;;
esac

case "$MODE" in
  --integration|--all)
    test_integration_fix_task_creation
    test_integration_coder_agent_with_mock_task
    test_integration_pr_agent_prereqs
    ;;
esac

# ─────────────────────────────────────────
# Summary
# ─────────────────────────────────────────
echo ""
echo "======================================"
echo " Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC}"
echo "======================================"

if [[ $FAIL -gt 0 ]]; then
  exit 1
else
  exit 0
fi
