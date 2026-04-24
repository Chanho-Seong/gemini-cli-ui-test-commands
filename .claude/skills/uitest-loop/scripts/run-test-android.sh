#!/usr/bin/env bash
#
# run-test-android.sh — Android connected UI 테스트 실행
#
# 사용법:
#   bash run-test-android.sh --output-dir <dir> [OPTIONS]
#
# 옵션:
#   --output-dir <dir>      결과 JSON 출력 디렉토리 (필수)
#   --module <name>         Gradle 모듈명 (default: detect-platform.sh 자동 감지)
#   --variant <name>        buildVariant (default: debug → 실패 시 googleDebug 시도)
#   --device <id>           고정 디바이스 id (미지정 시 adb devices 전체)
#   --class <fqn>           테스트 클래스 (반복 지정 가능)
#   --suite <fqn>           테스트 스위트 (@RunWith(Suite.class) FQCN)
#   --method <name>         테스트 메서드 이름. --class 없이 단독 사용 가능 —
#                           androidTest 소스를 스캔해 메서드가 속한 클래스를 자동 감지.
#                           동일 메서드가 여러 클래스에 있으면 오류 중단 (--class 로 지명 필요).
#   --project-path <path>   결과 메타데이터용 (default: .)
#   --dry-run               계획만 출력
#
# 결과: <output-dir>/all_uitest_results.json
#

set -u  # -e 제거: 테스트 실패 시에도 결과 파싱해야 함
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Defaults ──────────────────────────────────────────────────────────────
OUTPUT_DIR=""
MODULE=""
BUILD_VARIANT=""   # 미지정 시 detect-variants.sh 로 자동 감지
DEVICE_ID=""
TEST_CLASSES=()
TEST_SUITE=""
TEST_METHOD=""
PROJECT_PATH_META="."
DRY_RUN=false

log() { echo "[run-test-android] $*"; }

# ─── Parse args ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    "")             shift ;;   # 빈 인자는 무시 (backslash continuation 문제 방어)
    --output-dir)   OUTPUT_DIR="${2:-}"; shift 2 ;;
    --module)       MODULE="${2:-}"; shift 2 ;;
    --variant)      BUILD_VARIANT="${2:-}"; shift 2 ;;
    --device)       DEVICE_ID="${2:-}"; shift 2 ;;
    --class)        [[ -n "${2:-}" ]] && TEST_CLASSES+=("$2"); shift 2 ;;
    --suite)        TEST_SUITE="${2:-}"; shift 2 ;;
    --method)       TEST_METHOD="${2:-}"; shift 2 ;;
    --project-path) PROJECT_PATH_META="${2:-.}"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)      sed -n '3,20p' "$0"; exit 0 ;;
    *) echo "unknown option: '$1'" >&2; exit 2 ;;
  esac
done

[[ -z "$OUTPUT_DIR" ]] && { echo "--output-dir is required" >&2; exit 2; }
mkdir -p "$OUTPUT_DIR"

LOG_PATH="$OUTPUT_DIR/run-test-android.log"
RESULT_FILE="$OUTPUT_DIR/all_uitest_results.json"

# ─── Module auto-detection ─────────────────────────────────────────────────
if [[ -z "$MODULE" ]]; then
  eval "$(bash "$SCRIPT_DIR/detect-platform.sh")"
  MODULE="${MAIN_MODULE:-app}"
  [[ "$MODULE" == "." ]] && MODULE="app"
fi
MODULE_PATH="${MODULE//://}"

# ─── Variant auto-detection ────────────────────────────────────────────────
if [[ -z "$BUILD_VARIANT" ]]; then
  log "Detecting buildVariant for module '$MODULE'..."
  # --fast 모드로 build.gradle 만 파싱 (gradle 호출 회피)
  VARIANT_INFO="$(bash "$SCRIPT_DIR/detect-variants.sh" --module "$MODULE" --fast --prefer debug 2>/dev/null || echo '{}')"
  BUILD_VARIANT="$(python3 -c "import json,sys; d=json.loads(sys.stdin.read() or '{}'); print(d.get('recommended',''))" <<<"$VARIANT_INFO")"
  AVAILABLE="$(python3 -c "import json,sys; d=json.loads(sys.stdin.read() or '{}'); print(', '.join(d.get('variants',[])))" <<<"$VARIANT_INFO")"
  if [[ -z "$BUILD_VARIANT" ]]; then
    log "Could not detect any buildVariant from $MODULE/build.gradle*. Specify --variant explicitly."
    log "Try: ./gradlew :${MODULE}:tasks --all | grep 'assemble.*AndroidTest'"
    exit 2
  fi
  log "Auto-detected variant: $BUILD_VARIANT (available: $AVAILABLE)"
fi

# ─── Gradle task name & APK path ──────────────────────────────────────────
CAP="$(echo "${BUILD_VARIANT:0:1}" | tr '[:lower:]' '[:upper:]')${BUILD_VARIANT:1}"
GRADLE_ASSEMBLE_TASK=":${MODULE}:assemble${CAP}"
GRADLE_TEST_TASK=":${MODULE}:assemble${CAP}AndroidTest"

case "$BUILD_VARIANT" in
  *[Rr]elease) BUILD_TYPE="release" ;;
  *[Bb]eta)    BUILD_TYPE="beta" ;;
  *)           BUILD_TYPE="debug" ;;
esac

FLAVOR="${BUILD_VARIANT%[Dd]ebug}"
FLAVOR="${FLAVOR%[Rr]elease}"
FLAVOR="${FLAVOR%[Bb]eta}"
FLAVOR="$(echo "$FLAVOR" | tr '[:upper:]' '[:lower:]')"

if [[ -z "$FLAVOR" ]]; then
  APK_SUBPATH="$BUILD_TYPE"
  APK_BASENAME="${MODULE_PATH##*/}-$BUILD_TYPE"
else
  APK_SUBPATH="$FLAVOR/$BUILD_TYPE"
  APK_BASENAME="${MODULE_PATH##*/}-$FLAVOR-$BUILD_TYPE"
fi

APP_APK="./${MODULE_PATH}/build/outputs/apk/${APK_SUBPATH}/${APK_BASENAME}.apk"
TEST_APK="./${MODULE_PATH}/build/outputs/apk/androidTest/${APK_SUBPATH}/${APK_BASENAME}-androidTest.apk"

# ─── Auto-resolve class from method (method-only case) ───────────────────
# --method 만 주어지고 --class/--suite 가 없으면 androidTest 소스에서 해당 메서드를 가진
# 클래스를 스캔해 자동 감지한다. 2개 이상 매칭되면 종료 (사용자가 --class 로 지명).
if [[ ${#TEST_CLASSES[@]} -eq 0 && -z "$TEST_SUITE" && -n "$TEST_METHOD" ]]; then
  log "Auto-resolving test class for method '$TEST_METHOD' under module '$MODULE'..."
  RESOLVED_CLASS="$(python3 "$SCRIPT_DIR/resolve-test-class.py" --platform android --root "./${MODULE_PATH}" --method "$TEST_METHOD")"
  RESOLVE_RC=$?
  if [[ $RESOLVE_RC -ne 0 || -z "$RESOLVED_CLASS" ]]; then
    exit ${RESOLVE_RC:-2}
  fi
  log "Auto-detected class: $RESOLVED_CLASS (method=$TEST_METHOD)"
  TEST_CLASSES+=("$RESOLVED_CLASS")
fi

# ─── Test filter (class/suite/method) ─────────────────────────────────────
INSTR_CLASS_VALUES=()

if [[ -n "$TEST_SUITE" ]]; then
  INSTR_CLASS_VALUES+=("$TEST_SUITE")
fi

for c in "${TEST_CLASSES[@]:-}"; do
  [[ -z "$c" ]] && continue
  if [[ -n "$TEST_METHOD" && "$c" != *"#"* ]]; then
    INSTR_CLASS_VALUES+=("${c}#${TEST_METHOD}")
  else
    INSTR_CLASS_VALUES+=("$c")
  fi
done

INSTRUMENT_CLASS_ARG=""
if [[ ${#INSTR_CLASS_VALUES[@]} -gt 0 ]]; then
  CSV="$(IFS=,; echo "${INSTR_CLASS_VALUES[*]}")"
  INSTRUMENT_CLASS_ARG="-e class ${CSV}"
fi

# ─── Write selectionFilter header ─────────────────────────────────────────
CLASSES_JSON="$(printf '%s\n' "${TEST_CLASSES[@]:-}" | python3 -c 'import sys,json; print(json.dumps([l for l in sys.stdin.read().splitlines() if l]))')"
export CLASSES_JSON SUITE_FQN="$TEST_SUITE" METHOD_NAME="$TEST_METHOD"
SELECTION_FILTER_JSON=$(python3 <<'PY'
import json, os
print(json.dumps({
  "classes": json.loads(os.environ.get("CLASSES_JSON","[]")),
  "suite":   os.environ.get("SUITE_FQN","") or None,
  "method":  os.environ.get("METHOD_NAME","") or None,
}))
PY
)

# ─── Dry run ───────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  log "[DRY RUN] PLAN:"
  log "  module=$MODULE variant=$BUILD_VARIANT"
  log "  gradle: $GRADLE_ASSEMBLE_TASK $GRADLE_TEST_TASK"
  log "  device=${DEVICE_ID:-<all connected>}"
  log "  filter: $SELECTION_FILTER_JSON"
  log "  instrument arg: $INSTRUMENT_CLASS_ARG"
  log "  result file: $RESULT_FILE"
  exit 0
fi

# ─── Build ─────────────────────────────────────────────────────────────────
: > "$LOG_PATH"

log "Gradle build start ($GRADLE_ASSEMBLE_TASK, $GRADLE_TEST_TASK)"
chmod +x ./gradlew 2>/dev/null || true
REGRESSION="${REGRESSION:-regression}" ./gradlew "$GRADLE_ASSEMBLE_TASK" "$GRADLE_TEST_TASK" >> "$LOG_PATH" 2>&1
BUILD_EXIT=$?
if [[ $BUILD_EXIT -ne 0 ]]; then
  log "Gradle build failed (exit $BUILD_EXIT). See $LOG_PATH"
  python3 - "$RESULT_FILE" "$PROJECT_PATH_META" "$SELECTION_FILTER_JSON" <<'PY'
import json, sys
path, proj, sel = sys.argv[1:4]
with open(path, 'w', encoding='utf-8') as f:
    json.dump({
      'platform':'android','projectPath':proj,'totalCount':0,'passedCount':0,
      'failedCount':0,'failedTests':[],'selectionFilter':json.loads(sel),
      'error':'Gradle build failed'
    }, f, indent=2, ensure_ascii=False)
PY
  exit 1
fi
log "Build OK"

# ─── Device discovery ─────────────────────────────────────────────────────
DEVICES=()
if [[ -n "$DEVICE_ID" ]]; then
  if adb devices | awk 'NR>1 && $2=="device" {print $1}' | grep -qx "$DEVICE_ID"; then
    DEVICES=("$DEVICE_ID")
    log "Using pinned device: $DEVICE_ID"
  else
    log "Pinned device '$DEVICE_ID' not found. Connected:"
    adb devices | tee -a "$LOG_PATH"
    exit 1
  fi
else
  while IFS= read -r d; do
    [[ -n "$d" ]] && DEVICES+=("$d")
  done < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
fi

if [[ ${#DEVICES[@]} -eq 0 ]]; then
  log "No connected Android device"
  exit 1
fi
log "Devices: ${DEVICES[*]}"

# ─── Install APKs ─────────────────────────────────────────────────────────
for d in "${DEVICES[@]}"; do
  log "[$d] installing $APP_APK"
  adb -s "$d" install -r -t "$APP_APK" >> "$LOG_PATH" 2>&1
  log "[$d] installing $TEST_APK"
  adb -s "$d" install -r -t "$TEST_APK" >> "$LOG_PATH" 2>&1
done

# ─── Detect instrumentation package/runner ────────────────────────────────
FIRST="${DEVICES[0]}"
INSTR_LINES="$(adb -s "$FIRST" shell pm list instrumentation 2>/dev/null)"
MODULE_BASENAME="${MODULE_PATH##*/}"
INSTR_LINE="$(echo "$INSTR_LINES" | grep -i "$MODULE_BASENAME" | head -1)"
[[ -z "$INSTR_LINE" ]] && INSTR_LINE="$(echo "$INSTR_LINES" | head -1)"

if [[ -z "$INSTR_LINE" ]]; then
  log "Cannot detect instrumentation"
  exit 1
fi

COMP="$(echo "$INSTR_LINE" | sed 's|instrumentation:\([^ ]*\).*|\1|')"
TEST_PACKAGE="${COMP%%/*}"
TEST_RUNNER="${COMP##*/}"
log "Instrumentation: $TEST_PACKAGE/$TEST_RUNNER"

# ─── Run tests ────────────────────────────────────────────────────────────
# 단일 디바이스: 샤딩 없이 직접 실행 (출력은 shard_0_<dev>.log 로 동일 포맷 유지 → parser 호환)
# 다중 디바이스: numShards/shardIndex 로 병렬 실행
NUM_DEVICES=${#DEVICES[@]}
PIDS=()

if [[ "$NUM_DEVICES" -eq 1 ]]; then
  d="${DEVICES[0]}"
  test_log="$OUTPUT_DIR/shard_0_${d}.log"
  log "[$d] running (single-device, no sharding)"
  # shellcheck disable=SC2086
  adb -s "$d" shell am instrument -w -r \
    $INSTRUMENT_CLASS_ARG \
    "$TEST_PACKAGE/$TEST_RUNNER" > "$test_log" 2>&1 &
  PIDS+=($!)
else
  for i in "${!DEVICES[@]}"; do
    d="${DEVICES[$i]}"
    shard_log="$OUTPUT_DIR/shard_${i}_${d}.log"
    log "[$d] shard $i running"
    # shellcheck disable=SC2086
    adb -s "$d" shell am instrument -w -r \
      -e numShards "$NUM_DEVICES" \
      -e shardIndex "$i" \
      $INSTRUMENT_CLASS_ARG \
      "$TEST_PACKAGE/$TEST_RUNNER" > "$shard_log" 2>&1 &
    PIDS+=($!)
  done
fi

log "Waiting for test completion..."
FAILED=0
for i in "${!PIDS[@]}"; do
  if ! wait "${PIDS[$i]}"; then
    FAILED=$((FAILED+1))
  fi
done
if [[ "$NUM_DEVICES" -eq 1 ]]; then
  log "Test run finished (exit=$FAILED)"
else
  log "Test run finished (failed shards: $FAILED)"
fi

# ─── Parse results ────────────────────────────────────────────────────────
python3 "$SCRIPT_DIR/parse-am-instrument-results.py" \
  --shard-dir "$OUTPUT_DIR" \
  --output-dir "$OUTPUT_DIR" \
  --project-path "$PROJECT_PATH_META" \
  --selection-filter "$SELECTION_FILTER_JSON" \
  >> "$LOG_PATH" 2>&1 || log "parse-am-instrument-results failed; see $LOG_PATH"

if [[ -f "$RESULT_FILE" ]]; then
  FC="$(python3 -c "import json; print(json.load(open('$RESULT_FILE')).get('failedCount',0))" 2>/dev/null || echo 0)"
  if [[ "$FC" -eq 0 ]]; then
    log "PASS: all tests passed"
    exit 0
  else
    log "FAIL: $FC failed tests"
    exit 1
  fi
else
  log "No result file generated"
  exit 1
fi
