#!/bin/bash

# ==========================================
# Usage 함수
# ==========================================
usage() {
    echo "Usage: $0 [--variant <buildVariant>] [--module <moduleName>] [--class <testClass>]"
    echo "  --variant   Gradle buildVariant (default: debug)"
    echo "              예: debug, release, beta, stagingDebug, prodBeta"
    echo "  --module    빌드 대상 모듈명 (default: app)"
    echo "              예: app, feature:login, core:network"
    echo "  --class     실행할 테스트 클래스 (FQCN). 여러 개 지정 가능 (미지정 시 전체 실행)"
    echo "              예: --class com.fineapp.yogiyo.test.SanitySuite"
    echo "              예: --class com.fineapp.yogiyo.test.LoginTest --class com.fineapp.yogiyo.test.HomeTest"
}

# ==========================================
# 인자 파싱
# ==========================================
BUILD_VARIANT="debug"
MODULE="app"
TEST_CLASSES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --variant) BUILD_VARIANT="$2"; shift 2 ;;
        --module)  MODULE="$2"; shift 2 ;;
        --class)   TEST_CLASSES+=("$2"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

# 모듈 경로 변환 (feature:login → feature/login, app → app)
MODULE_PATH="${MODULE//:///}"

# ==========================================
# buildVariant에서 Gradle 태스크명 및 APK 경로 생성
# ==========================================
VARIANT_CAPITALIZED="$(echo "${BUILD_VARIANT:0:1}" | tr '[:lower:]' '[:upper:]')${BUILD_VARIANT:1}"
GRADLE_ASSEMBLE_TASK=":${MODULE}:assemble${VARIANT_CAPITALIZED}"
GRADLE_TEST_TASK=":${MODULE}:assemble${VARIANT_CAPITALIZED}AndroidTest"

# buildType 분리 (debug, release, beta)
if [[ "$BUILD_VARIANT" == *"Release" || "$BUILD_VARIANT" == *"release" ]]; then
    BUILD_TYPE="release"
elif [[ "$BUILD_VARIANT" == *"Beta" || "$BUILD_VARIANT" == *"beta" ]]; then
    BUILD_TYPE="beta"
else
    BUILD_TYPE="debug"
fi

# flavor 추출 (buildType 부분 제거)
FLAVOR="${BUILD_VARIANT%[Dd]ebug}"
FLAVOR="${FLAVOR%[Rr]elease}"
FLAVOR="${FLAVOR%[Bb]eta}"
FLAVOR="$(echo "$FLAVOR" | tr '[:upper:]' '[:lower:]')"

# APK 경로 생성
if [ -z "$FLAVOR" ]; then
    APK_SUBPATH="${BUILD_TYPE}"
    APK_NAME="${MODULE_PATH##*/}-${BUILD_TYPE}"
else
    APK_SUBPATH="${FLAVOR}/${BUILD_TYPE}"
    APK_NAME="${MODULE_PATH##*/}-${FLAVOR}-${BUILD_TYPE}"
fi

# ==========================================
# 환경 변수 및 APK 경로 설정
# ==========================================
LOG_DIR="./test_results"

APP_APK="./${MODULE_PATH}/build/outputs/apk/${APK_SUBPATH}/${APK_NAME}.apk"
TEST_APK="./${MODULE_PATH}/build/outputs/apk/androidTest/${APK_SUBPATH}/${APK_NAME}-androidTest.apk"

mkdir -p "$LOG_DIR"

# ==========================================
# 1. Gradlew를 이용한 APK 빌드
# ==========================================
echo "[INFO] Gradle 빌드를 시작합니다 (${GRADLE_ASSEMBLE_TASK}, ${GRADLE_TEST_TASK})..."
echo "[INFO] Module: ${MODULE}, Build Variant: ${BUILD_VARIANT}"

# 혹시 모를 실행 권한 부여
chmod +x ./gradlew

# 앱과 테스트 앱을 한 번에 빌드합니다.
./gradlew "$GRADLE_ASSEMBLE_TASK" "$GRADLE_TEST_TASK"

# 빌드 명령어가 정상 종료되었는지 확인 ($?는 직전 명령어의 종료 코드)
if [ $? -ne 0 ]; then
    echo "[ERROR] Gradle 빌드에 실패했습니다. 스크립트를 중단합니다."
    exit 1
fi

echo "[SUCCESS] APK 빌드가 완료되었습니다!"

# ==========================================
# 2. 연결된 디바이스 확인
# ==========================================
if [ -n "$ANDROID_SERIAL" ]; then
    echo "[INFO] ANDROID_SERIAL 환경 변수가 설정되어 있습니다: $ANDROID_SERIAL"
    # ANDROID_SERIAL에 지정된 기기가 연결되어 있는지 확인
    if adb devices | grep -w "$ANDROID_SERIAL" | grep -w "device" > /dev/null; then
        DEVICES=("$ANDROID_SERIAL")
        echo "[INFO] 지정된 기기 ($ANDROID_SERIAL) 를 사용합니다."
    else
        echo "[ERROR] ANDROID_SERIAL에 지정된 기기 ($ANDROID_SERIAL) 가 연결되어 있지 않습니다. 테스트를 중단합니다."
        exit 1
    fi
else
    DEVICES=($(adb devices | grep -w "device" | awk '{print $1}'))
    echo "[INFO] ANDROID_SERIAL 환경 변수가 설정되어 있지 않습니다. 연결된 모든 기기를 사용합니다."
fi

NUM_SHARDS=${#DEVICES[@]}

if [ "$NUM_SHARDS" -eq 0 ]; then
    echo "[ERROR] 연결된 안드로이드 기기나 에뮬레이터가 없습니다. 테스트를 중단합니다."
    exit 1
fi

echo "[INFO] 총 $NUM_SHARDS 대의 기기를 발견했습니다."

# ==========================================
# 3. 모든 기기에 APK 자동 설치
# ==========================================
echo "[INFO] 모든 기기에 APK 설치를 시작합니다..."

for DEVICE_ID in "${DEVICES[@]}"; do
    echo "[INFO] [$DEVICE_ID] 앱 설치 중..."

    # -r: 기존 앱 유지 후 재설치, -t: test-only flag 허용
    adb -s "$DEVICE_ID" install -r -t "$APP_APK" > /dev/null
    adb -s "$DEVICE_ID" install -r -t "$TEST_APK" > /dev/null

    echo "[SUCCESS] [$DEVICE_ID] 설치 완료!"
done

# ==========================================
# 3-1. 테스트 패키지명/러너 자동 감지 (디바이스에서 조회)
# ==========================================
FIRST_DEVICE="${DEVICES[0]}"
# "instrumentation:com.fineapp.yogiyo.test/com.fineapp.yogiyo.CustomRunner (target=com.fineapp.yogiyo)"
INSTR_LINES=$(adb -s "$FIRST_DEVICE" shell pm list instrumentation 2>/dev/null)

# APK 파일명에서 모듈명을 추출하여 매칭
MODULE_BASENAME="${MODULE_PATH##*/}"
INSTR_LINE=$(echo "$INSTR_LINES" | grep -i "$MODULE_BASENAME" | head -1)

if [ -z "$INSTR_LINE" ]; then
    # 모듈명 매칭 실패 시 전체 목록의 첫 번째 항목 사용
    INSTR_LINE=$(echo "$INSTR_LINES" | head -1)
fi

if [ -z "$INSTR_LINE" ]; then
    echo "[ERROR] 테스트 패키지명 또는 러너를 자동 감지할 수 없습니다."
    echo "[INFO]  디바이스의 instrumentation 목록:"
    echo "$INSTR_LINES"
    exit 1
fi

# "instrumentation:<package>/<runner> ..." 에서 패키지와 러너 추출
INSTR_COMPONENT=$(echo "$INSTR_LINE" | sed 's|instrumentation:\([^ ]*\).*|\1|')
TEST_PACKAGE="${INSTR_COMPONENT%%/*}"
TEST_RUNNER="${INSTR_COMPONENT##*/}"

echo "[INFO] 자동 감지된 테스트 패키지: ${TEST_PACKAGE}"
echo "[INFO] 자동 감지된 테스트 러너: ${TEST_RUNNER}"

echo "[INFO] Instrumentation: ${TEST_PACKAGE}/${TEST_RUNNER}"

# 테스트 클래스 지정 시 -e class 인자 구성 (쉼표 구분)
INSTRUMENT_CLASS_ARG=""
if [ ${#TEST_CLASSES[@]} -gt 0 ]; then
    CLASS_CSV=$(IFS=,; echo "${TEST_CLASSES[*]}")
    INSTRUMENT_CLASS_ARG="-e class $CLASS_CSV"
    echo "[INFO] 지정된 테스트 클래스: ${CLASS_CSV}"
else
    echo "[INFO] 전체 테스트를 실행합니다."
fi

# ==========================================
# 4. 기기별로 Shard를 나누어 백그라운드 실행
# ==========================================
PIDS=()
for i in "${!DEVICES[@]}"; do
    DEVICE_ID="${DEVICES[$i]}"
    SHARD_INDEX=$i
    LOG_FILE="$LOG_DIR/shard_${SHARD_INDEX}_${DEVICE_ID}.log"

    echo "[INFO] [$DEVICE_ID] 테스트 시작 (Shard $SHARD_INDEX)..."

    adb -s "$DEVICE_ID" shell am instrument -w \
        -e numShards "$NUM_SHARDS" \
        -e shardIndex "$SHARD_INDEX" \
        $INSTRUMENT_CLASS_ARG \
        "$TEST_PACKAGE/$TEST_RUNNER" > "$LOG_FILE" 2>&1 &

    PIDS+=($!)
done

# ==========================================
# 5. 모든 백그라운드 프로세스 대기 및 결과 수집
# ==========================================
echo "[INFO] 모든 테스트가 백그라운드에서 실행 중입니다. 완료될 때까지 대기합니다..."

FAILED=0
for i in "${!PIDS[@]}"; do
    pid="${PIDS[$i]}"
    device="${DEVICES[$i]}"
    
    wait "$pid"
    EXIT_CODE=$?
    
    if [ $EXIT_CODE -ne 0 ]; then
        echo "[FAIL] [$device] 테스트 중 실패 또는 오류 발생 (Exit Code: $EXIT_CODE)"
        FAILED=$((FAILED + 1))
    else
        echo "[SUCCESS] [$device] 테스트 완료!"
    fi
done

# ==========================================
# 6. 최종 결과 리포트
# ==========================================
echo "------------------------------------------"
if [ $FAILED -eq 0 ]; then
    echo "[FINAL RESULT] 모든 UI 테스트가 성공적으로 완료되었습니다!"
    exit 0
else
    echo "[FINAL RESULT] 일부 테스트가 실패했습니다. (실패한 Shard 수: $FAILED)"
    echo "[INFO] 자세한 내용은 $LOG_DIR 폴더의 로그를 확인하세요."
    exit 1
fi