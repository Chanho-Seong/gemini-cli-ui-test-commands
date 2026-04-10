# GEMINI-CLI-UI-TEST-COMMAND 유틸리티

프로젝트 스크립트 모음입니다.

---

## 파이프라인 오케스트레이션

### run-pipeline.sh

E2E 파이프라인 오케스트레이터. 8단계 워크플로우(discover → create-tasks → run-tests → aggregate → verify → fix → **re-test** → PR)를 자동으로 실행합니다.

```bash
bin/run-pipeline.sh                              # 전체 실행
bin/run-pipeline.sh --skip-verify --skip-pr      # 검증/PR 스킵
bin/run-pipeline.sh --class CartAndroidViewTest   # 특정 클래스
bin/run-pipeline.sh --pattern "*Order*"           # 패턴 매칭
bin/run-pipeline.sh --dry-run                     # 실행 계획만 확인
bin/run-pipeline.sh --poll-interval 30            # 폴링 간격 (기본 15초)
bin/run-pipeline.sh --variant googleBeta --module yogiyo  # 빌드 설정
```

---

## 테스트 실행 (Gemini API 미사용)

### run-test-android.sh

APK를 한 번만 빌드하고, 연결된 모든 디바이스에 설치 후 `am instrument`로 샤딩 병렬 실행합니다.

```bash
bin/run-test-android.sh [--variant <buildVariant>] [--module <moduleName>] [--class <testClass>...]
# 예: bin/run-test-android.sh --variant googleBeta --module yogiyo --class com.example.MyTest
```

### run-test-ios.sh

`xcodebuild test`로 iOS UI 테스트를 실행합니다. 디바이스풀과 자동 연동되며, `trap EXIT`으로 비정상 종료 시에도 디바이스를 해제합니다.

```bash
bin/run-test-ios.sh <task_id> <test_class_fqn> --project <project_path>
bin/run-test-ios.sh <task_id> <test_class_fqn> --project <project_path> --dry-run
```

| 인자 | 설명 |
|------|------|
| `task_id` | 태스크 ID |
| `test_class_fqn` | 테스트 클래스 FQN |
| `--project` | iOS 프로젝트 경로 |
| `--dry-run` | 실행 없이 계획만 출력 |

---

## 결과 파싱 및 집계

### parse-am-instrument-results.py

`am instrument` 텍스트 출력을 파싱하여 `all_uitest_results.json` 파일을 생성합니다. INSTRUMENTATION_STATUS 키와 상태 코드(0=pass, -1=error, -2=failure)를 해석합니다.

```bash
bin/parse-am-instrument-results.py --shard-dir <dir> --output-dir <dir> --project-path <path>
```

### parse-android-test-results.py

Android JUnit XML 테스트 결과를 파싱하여 `uitest_results.json` 형식으로 출력합니다. `failure`/`error` 요소에서 `errorMessage`, `stackTrace`를 추출합니다.

**요구사항**: Python 3

```bash
bin/parse-android-test-results.py <xml_dir> -o <output.json> -p <project_path> [-m <module>]
```

| 인자 | 설명 |
|------|------|
| `xml_dir` | TEST-*.xml 파일이 있는 디렉토리 (예: `build/outputs/androidTest-results/connected/`) |
| `-o`, `--output` | 출력 JSON 파일 경로 |
| `-p`, `--project-path` | 프로젝트 경로 (예: `.gemini/agents/workspace/Yogiyo_Android_for_ai`) |
| `-m`, `--module` | Android 모듈명 (testFilePath용, 비우면 경로에서 자동 추론) |

## 검증 결과 처리

### split-failures.py

실패한 테스트를 N개의 샤드로 라운드 로빈 분배합니다. 다중 디바이스 병렬 검증에 사용됩니다.

```bash
python3 bin/split-failures.py --input <aggregated.json> --num-shards <N> --output-dir <dir>
# 출력: verify_shard_0_uitest_results.json, verify_shard_1_uitest_results.json, ...
```

### merge-verification-results.py

다중 디바이스에서 실행된 verifier-agent의 검증 결과를 하나로 병합합니다. verifier-agent가 실패한 경우 집계 결과를 사용하고 모든 실패를 "SKIPPED" 상태로 표시합니다.

```bash
python3 bin/merge-verification-results.py --dir <logs_dir> --output <output.json> --aggregated <aggregated.json>
```

---

## 에이전트 실행 및 관리

### run-agent-with-retry.sh

에이전트를 백그라운드에서 실행하고, 모델 용량 제한 오류(MODEL_CAPACITY_EXHAUSTED, No Capacity available 등) 시 다른 모델로 자동 재시도합니다.

**모델 선택 규칙:**
- `verifier-agent`: flash 우선 (2.5-flash → 3-flash → 2.5-pro) — 동시 실행이 많으므로 rate limit에 강한 flash 모델 우선
- 그 외 에이전트: pro 우선 (3-pro → 2.5-pro → 3-flash → 2.5-flash)
- 참고: 테스트 실행은 `run-test-android.sh`/`run-test-ios.sh`로 직접 수행되므로 Gemini API를 사용하지 않습니다.

```bash
bin/run-agent-with-retry.sh <agent> <task_id> <log_file> "<prompt>" &
```

### reconcile-tasks.sh

`.gemini/agents/tasks/` 하위의 task 파일을 주기적으로 검사하여, 실패한 running 태스크를 pending으로 되돌리고 재시도 정보를 `.failed` 파일에 누적합니다.

**요구사항**: `jq` 또는 `python3` (JSON 처리용)

```bash
bin/reconcile-tasks.sh                  # 수동 실행
bin/reconcile-tasks.sh --schedule       # cron 예약 (기본 5분 간격)
bin/reconcile-tasks.sh --schedule 10    # cron 예약 (10분 간격)
bin/reconcile-tasks.sh --show-schedule  # 현재 cron 예약 확인
```

**동작 규칙:**
- `status: "running"`인 task의 logFile을 읽어 실패 패턴이 있으면 `"pending"`으로 리셋
- `.failed` 파일: `retryCount`와 `errors` 배열에 타임스탬프 및 에러 발췌를 누적

### reset-tasks.sh

태스크 초기화/정리 유틸리티. 관련 프로세스를 종료하고 태스크, 로그, 센티널, 디바이스 잠금을 삭제합니다.

```bash
bin/reset-tasks.sh                    # 기본 리셋
bin/reset-tasks.sh --running          # running 상태 태스크만 리셋
bin/reset-tasks.sh --agent verifier-agent  # 특정 에이전트 태스크만 리셋
bin/reset-tasks.sh --clean            # 전체 삭제 (태스크, 로그, 센티널, 잠금 모두)
bin/reset-tasks.sh --dry-run          # 대상 확인만 (실제 삭제 없음)
```

---

## 디바이스 풀

### device-pool.sh

디바이스 풀 매니저. 병렬 테스트/검증 시 디바이스 충돌을 방지합니다.

```bash
bin/device-pool.sh discover   # 연결된 디바이스 스캔
bin/device-pool.sh acquire    # 유휴 디바이스 1대 잠금
bin/device-pool.sh release    # 잠금 해제
bin/device-pool.sh status     # 디바이스 풀 상태 조회
bin/device-pool.sh cleanup    # 죽은 PID / TTL 만료 잠금 정리
bin/device-pool.sh count      # 가용 디바이스 수 조회
```

---

## 공통 유틸리티

### log-utils.sh

다른 셸 스크립트에서 `source`하여 사용하는 공유 로깅 함수 모음입니다.

```bash
source bin/log-utils.sh
```

### write-json.py / repair-json.py

안전한 JSON 기록 및 손상된 JSON 복구 유틸리티입니다.

### simple-test-by-name.sh

gemini-cli의 `-e` 플래그와 extension 이름으로 동작을 확인하는 간단한 테스트 스크립트입니다.

```bash
bin/simple-test-by-name.sh
```
