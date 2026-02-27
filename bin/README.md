# GEMINI-CLI-UI-TEST-COMMAND 유틸리티

프로젝트 스크립트 모음입니다.

---

## run-agent-with-retry.sh

에이전트를 백그라운드에서 실행하고, 모델 용량 제한 오류(MODEL_CAPACITY_EXHAUSTED, No Capacity available 등) 시 다른 모델로 자동 재시도합니다.

**모델 선택 규칙:**
- `tester-agent`: flash (1차) → pro (재시도)
- `coder-agent`, `verifier-agent`, `reviewer-agent` 등: pro (1차) → flash (재시도)

### 사용법

```bash
bin/run-agent-with-retry.sh <agent> <task_id> <log_file> "<prompt>" &
```

`/agents:run` 명령에서 에이전트 실행 시 이 스크립트를 사용합니다.

---

## reconcile-tasks.sh

`.gemini/agents/tasks/` 하위의 task 파일을 주기적으로 검사하여, 실패한 running 태스크를 pending으로 되돌리고 재시도 정보를 `.failed` 파일에 누적합니다.

**요구사항**: `jq` 또는 `python3` (JSON 처리용)

### 사용법

```bash
# 태스크 조정 실행 (수동)
bin/reconcile-tasks.sh

# cron 예약 (기본 5분 간격)
bin/reconcile-tasks.sh --schedule

# cron 예약 (분 단위 지정, 예: 10분)
bin/reconcile-tasks.sh --schedule 10

# 현재 cron 예약 확인
bin/reconcile-tasks.sh --show-schedule
```

### 동작 규칙

- `status: "running"`인 task의 logFile을 읽어 실패 패턴(MODEL_CAPACITY_EXHAUSTED, Max attempts reached 등)이 있으면:
  - status를 `"pending"`으로 변경
  - `.gemini/agents/tasks/<Task_ID>.failed` 생성/갱신
- `.failed` 파일: `retryCount`와 `errors` 배열에 타임스탬프 및 에러 발췌를 누적

### cron 제거

```bash
crontab -e
# reconcile-tasks.sh 관련 줄 삭제
```

---

## parse-android-test-results.py

Android JUnit XML 테스트 결과를 파싱하여 `uitest_results.json` 형식으로 출력합니다. `failure`/`error` 요소에서 `errorMessage`, `stackTrace`를 추출합니다.

**요구사항**: Python 3

### 사용법

```bash
bin/parse-android-test-results.py <xml_dir> -o <output.json> -p <project_path> [-m <module>]
```

### 인자

| 인자 | 설명 |
|------|------|
| `xml_dir` | TEST-*.xml 파일이 있는 디렉토리 (예: `build/outputs/androidTest-results/connected/`) |
| `-o`, `--output` | 출력 JSON 파일 경로 |
| `-p`, `--project-path` | 프로젝트 경로 (예: `.gemini/agents/workspace/Yogiyo_Android_for_ai`) |
| `-m`, `--module` | Android 모듈명 (testFilePath용, 비우면 경로에서 자동 추론) |

### 예시

```bash
bin/parse-android-test-results.py \
  .gemini/agents/workspace/Yogiyo_Android_for_ai/yogiyo/build/outputs/androidTest-results/connected/debug/flavors/google \
  -o .gemini/agents/logs/task_xxx_uitest_results.json \
  -p .gemini/agents/workspace/Yogiyo_Android_for_ai \
  -m yogiyo
```

---

## simple-test-by-name.sh

gemini-cli의 `-e` 플래그와 extension 이름으로 동작을 확인하는 간단한 테스트 스크립트입니다. `tdd-agent` 확장을 사용해 "Hello, who are you?" 프롬프트를 실행합니다.

### 사용법

```bash
bin/simple-test-by-name.sh
```
