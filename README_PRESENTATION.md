# Gemini CLI: 프롬프트 드리븐 오케스트레이터 & UITest

---

## 1. 프롬프트 드리븐 오케스트레이터 소개

### 1.1 개요

**프롬프트 드리븐 오케스트레이터**는 Gemini CLI의 네이티브 기능만으로 구축된 멀티 에이전트 오케스트레이션 시스템입니다. 코드 한 줄 없이, **프롬프트 엔지니어링**만으로 복잡한 비동기 작업을 수행하는 전문화된 AI 에이전트들을 조율합니다.

> 참고: [How I Turned Gemini CLI into a Multi-Agent System with Just Prompts](https://aipositive.substack.com/p/how-i-turned-gemini-cli-into-a-multi)

### 1.2 핵심 철학: 디스크 기반 상태 관리 (Filesystem-as-State)

Anthropic의 [Building a Sub-Agent with Claude](https://docs.anthropic.com/en/docs/claude-code/sub-agents) 문서에서 영감을 받은 **파일시스템-as-상태** 패턴을 채택합니다.

- **복잡한 백그라운드 프로세스 관리 없음**: 전체 시스템 상태(태스크 큐, 플랜, 로그)가 구조화된 디렉터리에 저장됩니다.
- **투명성과 디버깅 용이**: 외부 DB나 프로세스 매니저 없이, 파일만으로 상태를 추적할 수 있습니다.
- **Stateless Worker**: 각 에이전트는 디스크의 태스크 파일을 읽고, 작업을 수행한 뒤 `.done` 센티널 파일로 완료를 알립니다.

### 1.3 커스텀 커맨드의 힘

Gemini CLI 커스텀 커맨드는 `.toml` 텍스트 파일로 정의됩니다.

| 특성 | 설명 |
|------|------|
| **구성** | `.gemini/commands/` 디렉터리에 저장된 `.toml` 파일 |
| **핵심** | `prompt` 필드에 AI가 수행할 지시를 정의 |
| **결과** | 파일명 기반으로 새 CLI 명령 생성 (예: `agents/start.toml` → `/agents:start`) |

### 1.4 에이전트 실행 방식

오케스트레이터는 **새로운 독립적인 `gemini-cli` 인스턴스**를 실행합니다.

- `gemini -e <agent-extension> -y -p "<prompt>"` 형태로 호출
- `-y` (yolo) 플래그로 내부 도구 호출 자동 승인
- **Identity Crisis 방지**: 에이전트에게 "You are the &lt;agent-name&gt;. Your Task ID is &lt;id&gt;. Your task is to: ..." 형태로 명시적 역할 부여

### 1.5 주의사항

- **실험적 설정**: `--yolo` 플래그 사용 시 모든 도구 호출이 자동 승인되므로 주의가 필요합니다.
- **프로덕션 미권장**: 샌드박싱, 체크포인팅 등 보안 기능이 없는 PoC 수준입니다.

---

## 2. 프롬프트 드리븐 UITest 소개

### 2.1 개요

이 프로젝트는 프롬프트 드리븐 오케스트레이터를 **Android/iOS UI 테스트 자동화**에 적용한 사례입니다. 6개의 전문화된 에이전트가 협업하여 **테스트 실행 → 실패 검증 → 코드 수정 → PR 생성**까지 전체 워크플로우를 자동으로 수행합니다.

### 2.2 테스트 파이프라인 (End-to-End)

```
/agents:pipeline  (또는 bin/run-pipeline.sh)

  ┌─────────────┐     ┌───────────┐     ┌──────────┐     ┌───────────┐     ┌──────────┐     ┌──────────┐
  │  1. Discover │ ──▶ │ 2. Test   │ ──▶ │ 3. Aggr  │ ──▶ │ 4. Verify │ ──▶ │ 5. Fix   │ ──▶ │ 6. PR    │
  │  Devices     │     │ Planning  │     │ Results  │     │ on Device │     │ Code     │     │ Create   │
  └─────────────┘     │ + Run     │     └──────────┘     └───────────┘     └──────────┘     └──────────┘
   device-pool.sh      └───────────┘
   discover             tester-agent                      verifier-agent    coder-agent      pr-agent
                        (병렬, 디바이스풀 제한)               (mobile-mcp)      (병렬, 클래스별)
```

**핵심 변화**: 이전에는 각 단계를 수동으로 커맨드 실행해야 했지만, 이제 **`/agents:pipeline` 한 번으로 전체 흐름이 자동 실행**됩니다.

### 2.3 에이전트 역할

| 에이전트 | 역할 | 주요 출력 |
|----------|------|-----------|
| **tester-agent** | 워크스페이스 내 Android/iOS 프로젝트 검색 → UI 테스트 실행 → JUnit XML 파싱 | `uitest_results.json` |
| **verifier-agent** | 실패한 테스트를 mobile-mcp로 실제 기기에서 재현 → 에뮬레이터 전용 이슈 vs 실제 버그 분류 | `device_verification.json` |
| **coder-agent** | `verifiedFailures` 기반으로 테스트 코드 최소 수정 → 컴파일 체크 → 커밋 | `fix_report.json` + git commit |
| **pr-agent** | fix_report 수집 → feature 브랜치 생성 → GitHub PR 생성 | `pr_report.json` + GitHub PR |
| **reviewer-agent** | 코드 리뷰. 버그, 스타일 위반, 개선점 분석 | 플랜 파일 업데이트 |
| **tdd-agent** | TDD 방식으로 최소한의 실패 테스트 코드 작성 | 테스트 파일 경로 |

### 2.4 디바이스 풀 매니저 (Device Pool Manager)

병렬 테스트 실행 시 **OS별 가용 디바이스 수만큼만 동시 실행**하고, 태스크 간 디바이스 충돌을 방지합니다.

```
Android 단말 3대 연결 상태에서 테스트 클래스 10개 실행 시:

  task_1 ──▶ emulator-5554 (잠금)     task_4 ──▶ 대기...
  task_2 ──▶ R5CT1234567  (잠금)       ↓ task_1 완료 → emulator-5554 해제
  task_3 ──▶ emulator-5556 (잠금)     task_4 ──▶ emulator-5554 (재잠금)
                                       ...반복
```

| 기능 | 설명 |
|------|------|
| `device-pool.sh discover` | `adb devices` / `xcrun simctl list`로 OS별 디바이스 스캔 |
| `device-pool.sh acquire` | 유휴 디바이스 1대를 원자적(`mkdir`) 잠금, device_id 반환 |
| `device-pool.sh release` | 잠금 해제 |
| `device-pool.sh cleanup` | 죽은 PID / TTL 만료(30분) 잠금 자동 정리 |

**자동 연동**: `run-agent-with-retry.sh`가 tester-agent/verifier-agent 실행 시 자동으로 acquire → 실행 → release. `trap`으로 비정상 종료 시에도 해제 보장.

### 2.5 UITest 커맨드

| 커맨드 | 설명 |
|--------|------|
| `/agents:pipeline` | **전체 파이프라인 한 번에 실행** (discover → test → aggregate → verify → fix → PR) |
| `/agents:test-planing` | CriticalRT 스위트 → 클래스별 tester-agent 태스크 자동 생성 |
| `/agents:run-all [agent_type]` | 모든 pending 태스크 일괄 실행 (디바이스풀 제한 적용) |
| `/agents:verify <path>` | verifier-agent 태스크 생성 (실패 UI 테스트 실기기 검증) |
| `/agents:fix <path>` | coder-agent 태스크 병렬 생성 (클래스별 1개, 자동 실행) |
| `/agents:pr` | pr-agent 태스크 생성 (fix_report 수집 → GitHub PR) |

### 2.6 지원 플랫폼

- **Android**: `./gradlew connectedDebugAndroidTest` + `ANDROID_SERIAL` 디바이스 지정, `bin/parse-android-test-results.py`
- **iOS**: `xcodebuild test` + `-destination 'id=<device_id>'` 디바이스 지정, `.xcresult` bundle 파싱

---

## 3. 상세 내용

### 3.1 디렉터리 구조

```
.gemini/
├── agents/
│   ├── tasks/          # 태스크 JSON (상태, pending/running/complete) + .done/.failed
│   ├── plans/          # 에이전트 장기 계획용 마크다운
│   ├── logs/           # 실행 로그, uitest_results.json, device_verification.json, fix_report.json
│   ├── state/          # 디바이스 풀 상태 (NEW)
│   │   ├── device_pool.json    # OS별 디바이스 목록 및 상태
│   │   └── locks/              # 디바이스별 잠금 파일 (원자적 mkdir 기반)
│   └── workspace/      # 실제 테스트 대상 프로젝트 (Android/iOS)
├── commands/
│   └── agents/         # /agents:* 커맨드 정의 (.toml)
│       ├── pipeline.toml   # 전체 파이프라인 (NEW)
│       ├── run-all.toml    # 일괄 실행 (NEW)
│       ├── fix.toml        # 코드 수정
│       └── pr.toml         # PR 생성
├── extensions/
│   ├── tester-agent/       # UI 테스트 실행 (디바이스풀 연동)
│   ├── verifier-agent/     # 실패 테스트 기기 검증 (디바이스풀 연동)
│   ├── coder-agent/        # 테스트 코드 수정
│   └── pr-agent/           # GitHub PR 생성
├── rules/
│   ├── android-uitest-conventions.md   # Android UITest 컨벤션 (NEW)
│   └── ios-uitest-conventions.md       # iOS UITest 컨벤션 (NEW)
bin/
├── device-pool.sh                  # 디바이스 풀 매니저 (NEW)
├── run-pipeline.sh                 # E2E 파이프라인 오케스트레이터 (NEW)
├── aggregate-test-results.py       # 결과 집계 스크립트 (NEW)
├── run-agent-with-retry.sh         # 모델 재시도 + 디바이스풀 연동
├── reconcile-tasks.sh              # 태스크 상태 정합 + 디바이스 잠금 정리
├── parse-android-test-results.py   # JUnit XML → uitest_results.json
├── write-json.py                   # 안전한 JSON 기록
└── repair-json.py                  # JSON 복구
```

### 3.2 커맨드 목록

| 커맨드 | 설명 | 카테고리 |
|--------|------|----------|
| `/agents:pipeline [옵션]` | **전체 파이프라인 자동 실행** | 파이프라인 |
| `/agents:test-planing` | CriticalRT 스위트 → 클래스별 tester-agent 태스크 생성 | 테스트 |
| `/agents:run-all [agent_type]` | 모든 pending 태스크 일괄 실행 (디바이스풀 제한) | 실행 |
| `/agents:run [task_id]` | 단일 태스크 실행 | 실행 |
| `/agents:verify <path>` | verifier-agent 태스크 생성 (실기기 검증) | 검증 |
| `/agents:fix <path>` | coder-agent 태스크 병렬 생성 (클래스별 수정) | 수정 |
| `/agents:pr [project_path]` | pr-agent 태스크 생성 (GitHub PR) | PR |
| `/agents:start <agent> "<prompt>"` | 범용 태스크 생성 | 기본 |
| `/agents:status [task_id]` | 태스크 상태 조회 | 모니터링 |
| `/agents:type` | 사용 가능한 에이전트 목록 | 조회 |

### 3.3 uitest_results.json 구조

```json
{
  "platform": "android",
  "projectPath": ".gemini/agents/workspace/<project_name>",
  "totalCount": 15,
  "passedCount": 12,
  "failedCount": 3,
  "failedTests": [
    {
      "className": "kr.co.example.SomeAndroidViewTest",
      "testName": "testExample",
      "errorMessage": "View with id ... was not found",
      "stackTrace": "...",
      "testFilePath": "path/to/TestFile.kt"
    }
  ]
}
```

### 3.4 device_verification.json 구조

```json
{
  "deviceId": "emulator-5554",
  "projectPath": ".gemini/agents/workspace/Yogiyo_Android_for_ai",
  "verifiedFailures": [
    {
      "className": "...",
      "testName": "...",
      "deviceResult": "FAILED",
      "verificationNote": "실제 단말에서도 동일 실패"
    }
  ],
  "verifiedPasses": [
    {
      "className": "...",
      "testName": "...",
      "deviceResult": "PASSED",
      "verificationNote": "에뮬레이터 전용 이슈 - 코더 스킵"
    }
  ]
}
```

### 3.5 예시 워크플로우

**방법 1: 전체 파이프라인 (One Command)**

```bash
# 전체 워크플로우 자동 실행 (가장 간단)
bin/run-pipeline.sh

# 또는 Gemini CLI 커맨드로
gemini /agents:pipeline

# 옵션: 디바이스 없이 실행 (verify 스킵)
bin/run-pipeline.sh --skip-verify

# 옵션: 드라이런 (실행 없이 계획만 확인)
bin/run-pipeline.sh --dry-run
```

**방법 2: 단계별 수동 실행**

```bash
# 1. 디바이스 스캔
bin/device-pool.sh discover
# Output: Discovered: Android 2 (2 idle), iOS 0 (0 idle)

# 2. 테스트 태스크 생성
gemini /agents:test-planing

# 3. 일괄 실행 (디바이스 수만큼 병렬)
gemini /agents:run-all tester-agent

# 4. 결과 집계
python3 bin/aggregate-test-results.py
# Output: Total: 25, Passed: 22, Failed: 3

# 5. 실기기 검증
gemini /agents:verify .gemini/agents/logs/aggregated_uitest_results.json
gemini /agents:run

# 6. 코드 수정 (클래스별 병렬)
gemini /agents:fix .gemini/agents/logs/task_xxx_device_verification.json

# 7. PR 생성
gemini /agents:pr
gemini /agents:run
```

**디바이스 풀 모니터링**

```bash
bin/device-pool.sh status
# Output:
# [ANDROID] Total: 3, Idle: 1, Locked: 2
# ID                       Model               Status     Locked By
# --------------------------------------------------------------------------------
# emulator-5554            Pixel_7              locked     task_123_fix_0
# R5CT1234567              SM-S911N             locked     task_124_fix_1
# emulator-5556            Pixel_8              idle       -
```

### 3.6 모델 재시도 전략 (run-agent-with-retry.sh)

- **tester-agent**: flash → pro → 2.5-pro → 2.5-flash (용량 오류 시 순차 재시도)
- **coder-agent, verifier-agent 등**: pro → flash → 2.5-pro → 2.5-flash

### 3.7 Gemini CLI 익스텐션

Gemini CLI 익스텐션은 프로젝트별로 AI의 역할, 도구, 설정을 확장하는 메커니즘입니다. 이 프로젝트의 서브 에이전트(tester-agent, verifier-agent, coder-agent 등)는 모두 익스텐션으로 정의됩니다.

**로드 경로**: `~/.gemini/extensions` 또는 프로젝트 내 `.gemini/extensions/`

**핵심 구성 요소**:

| 구성 요소 | 설명 |
|----------|------|
| `gemini-extension.json` | 익스텐션 매니페스트. `name`, `version`, `contextFileName` 등 정의 |
| `contextFileName` | 세션 시작 시 모델 컨텍스트에 로드되는 파일(예: `*-persona.md`). 에이전트의 역할, 제약, 워크플로우를 담음 |
| `mcpServers` | 익스텐션 전용 MCP 서버(예: mobile-mcp). 도구 범위를 제한하거나 확장 가능 |
| `commands/` | 커스텀 슬래시 커맨드(`.toml`). `commands/agents/run.toml` → `/agents:run` |
| `excludeTools` | 해당 익스텐션에서 사용 불가한 도구 목록. 읽기 전용 에이전트 등에 활용 |

**이 프로젝트에서의 사용**:

- 오케스트레이터는 `-e <extension-name>` 옵션으로 특정 익스텐션만 로드한 `gemini-cli` 인스턴스를 실행합니다.
- 예: `gemini -e tester-agent -y -p "..."` → tester-agent 페르소나와 제약만 적용된 전용 인스턴스가 실행됩니다.

> 참고: [Extension reference \| Gemini CLI](https://geminicli.com/docs/extensions/reference/)

### 3.8 End-to-End UITest 파이프라인 (구현 완료)

**전체 파이프라인**

```
  discover     test-planing    run-all       aggregate     verify        fix           pr
  ──────── ──▶ ──────────── ──▶ ──────── ──▶ ────────── ──▶ ──────── ──▶ ──────── ──▶ ────────
  디바이스      CriticalRT      병렬 실행     결과 병합     실기기 검증   코드 수정     PR 생성
  풀 초기화     스위트 분석      (디바이스풀)   (실패 집계)   (mobile-mcp)  (병렬, 커밋)  (gh CLI)
                                                   │
                                              실패 없음 → 종료
                                              실패 있음 → 다음 단계
```

**구현 상황**

| 단계 | 상태 | 커맨드/스크립트 | 비고 |
|------|------|----------------|------|
| Device Discovery | ✅ 구현 | `bin/device-pool.sh discover` | OS별 디바이스 스캔 + 잠금 관리 |
| Test Planning | ✅ 구현 | `/agents:test-planing` | 스위트 → 클래스별 태스크 |
| Test Execution | ✅ 구현 | `/agents:run-all` | 디바이스풀 제한 병렬 실행 |
| Result Aggregation | ✅ 구현 | `bin/aggregate-test-results.py` | 다수 결과 → 단일 파일 + 요약 |
| Device Verification | ✅ 구현 | `/agents:verify` | mobile-mcp 실기기 검증 |
| Code Fix | ✅ 구현 | `/agents:fix` | 클래스별 coder-agent 병렬 수정 |
| PR Creation | ✅ 구현 | `/agents:pr` | feature 브랜치 → GitHub PR |
| **Pipeline** | ✅ 구현 | `/agents:pipeline` / `bin/run-pipeline.sh` | **전체 자동화 (단일 커맨드)** |

**자동 분기 로직**: 각 단계 완료 후 결과를 확인하여 자동으로 다음 단계를 결정합니다.
- 실패 테스트 0개 → 파이프라인 조기 종료 ("수정 불필요")
- `verifiedFailures` 0개 → fix/PR 스킵 ("에뮬레이터 전용 이슈")
- 디바이스 미연결 → verify 스킵, 모든 실패를 coder-agent에 전달

### 3.9 디바이스 풀 아키텍처

병렬 테스트/검증 시 **디바이스 충돌을 방지**하는 핵심 메커니즘입니다.

**설계 원칙**: 프로젝트의 Filesystem-as-State 아키텍처와 일관되게 **파일 기반 잠금** 사용

```
.gemini/agents/state/
├── device_pool.json                # OS별 전체 디바이스 상태
└── locks/
    ├── emulator-5554.lock.d/       # 원자적 mkdir 기반 잠금
    │   └── info.json               # {taskId, agent, lockedAt, pid, os}
    └── R5CT1234567.lock.d/
        └── info.json
```

| 메커니즘 | 구현 |
|----------|------|
| **잠금 획득** | `mkdir` (POSIX 원자적 연산) |
| **잠금 해제** | `rm -rf lock.d/` (태스크 완료/실패 시) |
| **비정상 종료** | `trap EXIT` + `release_device()` |
| **고아 잠금** | PID 체크 + TTL 만료(30분) 자동 정리 |
| **연동** | `run-agent-with-retry.sh`가 자동 acquire/release |

### 3.10 Sanity 테스트 스위트

파이프라인 E2E 검증용으로 간단한 Sanity 테스트 25개(5클래스 x 5테스트)를 포함합니다.

| 테스트 클래스 | 검증 영역 |
|--------------|----------|
| `SanityAppLaunchTest` | 앱 실행, 메인 화면, 패키지명 |
| `SanityNavigationTest` | 딥링크 이동, 뒤로가기, 화면 회전 |
| `SanitySearchTest` | 검색 화면 진입, 키워드 검색 |
| `SanityGlobalHomeTest` | 글로벌홈 RecyclerView, 스크롤 |
| `SanityDeepLinkTest` | 각종 딥링크 동작 확인 |

`SanitySuite`로 한 번에 실행:
```bash
./gradlew :yogiyo:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=kr.co.yogiyo.test.SanitySuite
```

### 3.11 참고 자료

- **블로그**: [How I Turned Gemini CLI into a Multi-Agent System with Just Prompts](https://aipositive.substack.com/p/how-i-turned-gemini-cli-into-a-multi)
- **데모 비디오**: [See it in Action](https://aipositive.substack.com/i/169284045/see-it-in-action)
- **Anthropic**: [Building a Sub-Agent with Claude](https://docs.anthropic.com/en/docs/claude-code/sub-agents)
- **Gemini CLI 로드맵**: [공식 에이전트 기능 이슈](https://github.com/google-gemini/gemini-cli/issues/4168)

---

## Disclaimer

이 프로젝트는 **proof-of-concept** 실험입니다. 프로덕션 환경에서의 사용은 권장하지 않으며, `-y` 플래그 사용 시 보안 검증이 우회됩니다.
