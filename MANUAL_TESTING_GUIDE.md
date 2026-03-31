# 파이프라인 수동 테스트 가이드

이 프로젝트는 Gemini CLI 기반의 **UITest 자동화 파이프라인**으로, 7단계로 구성되어 있습니다. 각 단계를 수동으로 실행할 수 있습니다.

---

## 사전 준비

- **Gemini CLI** 설치 및 API 키 설정
- **Python 3.7+**, **adb** (Android), **git** 설치
- 테스트 대상 프로젝트가 `.gemini/agents/workspace/`에 위치해야 함
- Android 디바이스/에뮬레이터 연결 상태 확인

---

## 단계별 수동 실행

```bash
cd /path/to/gemini-cli-ui-test-commands

# 1. 디바이스 탐색
bin/device-pool.sh discover
bin/device-pool.sh status

# 2. 테스트 태스크 생성 (프로젝트 스캔 → 테스트 클래스별 태스크 생성)
gemini /agents:test-planing

# 3. 테스트 실행 (디바이스 수에 맞춰 병렬 실행)
gemini /agents:run-all tester-agent

# 4. 진행 상태 확인 (폴링)
gemini /agents:status

# 5. 결과 집계 (모든 테스트 결과를 하나로 병합)
python3 bin/aggregate-test-results.py

# 6. 실기기 검증 (에뮬레이터 전용 이슈 vs 실제 버그 분류)
gemini /agents:verify .gemini/agents/logs/aggregated_uitest_results.json
gemini /agents:run-all verifier-agent

# 7. 코드 수정 (검증된 실패 테스트 자동 수정)
gemini /agents:fix .gemini/agents/logs/<task_id>_device_verification.json
gemini /agents:run-all coder-agent

# 8. PR 생성
gemini /agents:pr
gemini /agents:run pr-agent
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
```

---

## 주요 산출물 위치

| 파일 | 위치 |
|------|------|
| 테스트 결과 | `.gemini/agents/logs/*_uitest_results.json` |
| 집계 결과 | `.gemini/agents/logs/aggregated_uitest_results.json` |
| 디바이스 검증 | `.gemini/agents/logs/*_device_verification.json` |
| 수정 리포트 | `.gemini/agents/logs/*_fix_report.json` |
| 태스크 상태 | `.gemini/agents/tasks/` |
| 디바이스 풀 | `.gemini/agents/state/device_pool.json` |

---

## 장애 대응

- **태스크 실패 복구**: `bin/reconcile-tasks.sh` (실패 태스크를 pending으로 리셋)
- **디바이스 락 해제**: `bin/device-pool.sh cleanup`
- **모델 용량 에러**: `run-agent-with-retry.sh`가 자동으로 다른 모델로 재시도 (flash → pro → 2.5-pro → 2.5-flash)
