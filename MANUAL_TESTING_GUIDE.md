# 파이프라인 수동 테스트 가이드

이 프로젝트는 Gemini CLI 기반의 **UITest 자동화 파이프라인**으로, 7단계로 구성되어 있습니다. 각 단계를 수동으로 실행할 수 있습니다. Android와 iOS 플랫폼을 모두 지원합니다.

---

## 사전 준비

- **Gemini CLI** 설치 및 API 키 설정
- **Python 3.7+**, **git** 설치
- **Android**: `adb` 설치, 디바이스/에뮬레이터 연결 상태 확인
- **iOS**: `xcodebuild`, `xcrun simctl` 사용 가능 확인
- 테스트 대상 프로젝트가 `.gemini/agents/workspace/`에 위치해야 함

---

## 단계별 수동 실행

### Android

```bash
cd /path/to/gemini-cli-ui-test-commands

# 1. 디바이스 탐색
bin/device-pool.sh discover
bin/device-pool.sh status

# 2. 테스트 태스크 생성 (프로젝트 스캔 → 테스트 클래스별 태스크 생성)
python3 bin/create-test-tasks.py                          # 기본: CriticalRTSuite
python3 bin/create-test-tasks.py --suite SanitySuite       # 특정 스위트
python3 bin/create-test-tasks.py --class CartAndroidViewTest  # 특정 클래스
python3 bin/create-test-tasks.py --pattern "*Home*"        # 패턴 매칭

# 3. 테스트 실행 (디바이스 수에 맞춰 병렬 실행, Gemini API 미사용)
# 방법 A: 일괄 실행 (run-all이 내부적으로 run-test-android.sh 호출)
gemini /agents:run-all tester-agent

# 방법 B: 직접 실행 (빌드 1회 + 디바이스 샤딩)
bin/run-test-android.sh --variant googleBeta --module yogiyo --class com.example.MyTest

# 방법 C: Gemini CLI 커맨드로 플랫폼 자동 감지 실행
gemini /agents:run-test --variant googleBeta --module yogiyo --class com.example.MyTest

# 4. 진행 상태 확인 (폴링)
gemini /agents:status

# 5. 결과 집계 (모든 테스트 결과를 하나로 병합)
python3 bin/aggregate-test-results.py

# 6. 실기기 검증 (에뮬레이터 전용 이슈 vs 실제 버그 분류, 다중 디바이스 병렬)
gemini /agents:verify .gemini/agents/logs/aggregated_uitest_results.json
gemini /agents:run-all verifier-agent

# 7. 코드 수정 (검증된 실패 테스트 자동 수정)
gemini /agents:fix .gemini/agents/logs/<task_id>_device_verification.json
gemini /agents:run-all coder-agent

# 8. PR 생성
gemini /agents:pr
gemini /agents:run pr-agent
```

### iOS

```bash
cd /path/to/gemini-cli-ui-test-commands

# 1. 디바이스 탐색
bin/device-pool.sh discover
bin/device-pool.sh status

# 2. 테스트 실행 (xcodebuild 기반, 디바이스풀 연동)
bin/run-test-ios.sh <task_id> <test_class_fqn> --project .gemini/agents/workspace/<project>

# 또는 Gemini CLI 커맨드로 자동 감지
gemini /agents:run-test --task <task_id>

# 3~8. Android와 동일 (결과 집계 → 검증 → 수정 → PR)
```

---

## 전체 파이프라인 한 번에 실행

```bash
# 전체 실행
bin/run-pipeline.sh

# 디바이스 검증 스킵 (디바이스 미연결 시)
bin/run-pipeline.sh --skip-verify

# 드라이런 (실행 계획만 확인)
bin/run-pipeline.sh --dry-run

# 커스텀 테스트 스위트 지정
bin/run-pipeline.sh --suite CustomTestSuite

# 특정 테스트 클래스만 실행
bin/run-pipeline.sh --class CartAndroidViewTest

# 패턴으로 테스트 클래스 필터링
bin/run-pipeline.sh --pattern "*Order*"
```

---

## 주요 산출물 위치

| 파일 | 위치 |
|------|------|
| 테스트 결과 | `.gemini/agents/logs/*_uitest_results.json` |
| 집계 결과 | `.gemini/agents/logs/aggregated_uitest_results.json` |
| 검증 샤드 입력 | `.gemini/agents/logs/verify_shard_*_uitest_results.json` |
| 디바이스 검증 | `.gemini/agents/logs/*_device_verification.json` |
| 병합 검증 결과 | `.gemini/agents/logs/merged_device_verification.json` |
| 수정 리포트 | `.gemini/agents/logs/*_fix_report.json` |
| 태스크 상태 | `.gemini/agents/tasks/` |
| 디바이스 풀 | `.gemini/agents/state/device_pool.json` |

---

## 태스크 초기화

```bash
# running 상태 태스크만 리셋
bin/reset-tasks.sh --running

# 특정 에이전트 태스크만 리셋
bin/reset-tasks.sh --agent tester-agent

# 전체 삭제 (태스크, 로그, 센티널, 잠금 모두 제거)
bin/reset-tasks.sh --clean

# 드라이런 (실제 삭제 없이 대상 확인)
bin/reset-tasks.sh --dry-run
```

---

## 장애 대응

- **태스크 실패 복구**: `bin/reconcile-tasks.sh` (실패 태스크를 pending으로 리셋)
- **태스크 전체 초기화**: `bin/reset-tasks.sh --clean` (프로세스 종료 + 태스크/로그/잠금 전체 삭제)
- **디바이스 락 해제**: `bin/device-pool.sh cleanup`
- **모델 용량 에러**: `run-agent-with-retry.sh`가 자동으로 다른 모델로 재시도 (pro → flash → 2.5-pro → 2.5-flash)
- **파이프라인 알림**: `.gemini/hooks/`의 라이프사이클 훅이 각 단계 전환 및 완료 시 macOS 데스크톱 알림을 전송합니다.
- **참고**: 파이프라인의 Stage 1~4(디바이스 발견 → 테스트 플래닝 → 테스트 실행 → 결과 집계)는 Gemini API를 사용하지 않으며, AI 에이전트는 Stage 5~7(검증/수정/PR)에서만 사용됩니다.
