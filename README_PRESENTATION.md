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

이 프로젝트는 프롬프트 드리븐 오케스트레이터를 **Android/iOS UI 테스트 자동화**에 적용한 사례입니다. **tester-agent**, **verifier-agent** 두 개의 전문화된 에이전트가 협업하여 테스트 실행 → 실패 검증 → 결과 분석까지 수행합니다.

### 2.2 테스트 파이프라인

```
[사용자] → /agents:start tester-agent "프롬프트"
       또는 /agents:test-planing  (CriticalRT 스위트 → 클래스별 태스크 자동 생성)
    → tester-agent: UI 테스트 실행 → uitest_results.json 생성
    → [실패 케이스 존재 시] /agents:verify <uitest_results.json>
    → verifier-agent: 실제 기기에서 실패 케이스 재검증
    → device_verification.json 생성 (verifiedFailures / verifiedPasses)
```

### 2.3 에이전트 역할

| 에이전트 | 역할 | 주요 출력 |
|----------|------|-----------|
| **tester-agent** (New) | 워크스페이스 내 Android/iOS 프로젝트 검색 → `connectedDebugAndroidTest` 또는 `xcodebuild test` 실행 → JUnit XML 파싱 → `*_uitest_results.json` 생성 | `failedTests` 배열 (className, testName, errorMessage, stackTrace) |
| **verifier-agent** (New) | `uitest_results.json`의 `failedTests`를 읽어 → mobile-mcp 도구로 실제 기기에서 시나리오 재현 → 에뮬레이터 전용 이슈 vs 실제 버그 분류 | `verifiedFailures` (코더에 전달), `verifiedPasses` (스킵) |
| **coder-agent** | 단일 코딩 태스크 수행. 플랜 파일을 읽고 `.gemini/agents/workspace/`에 코드 작성. | 생성한 코드 파일 경로 |
| **reviewer-agent** | 지정된 파일 경로의 코드 리뷰. 버그, 스타일 위반, 개선점 분석 후 플랜 파일 업데이트. | `Review complete.` |
| **tdd-agent** | TDD 방식으로 사용자 요청에 대한 최소한의 실패 테스트 코드 작성. 기능 요청 분석 후 새 테스트 파일 생성. | 생성한 테스트 파일 경로 |

### 2.4 UITest 전용 커맨드

- **`/agents:test-planing`**  
  워크스페이스 내 Android/iOS 프로젝트에서 CriticalRT 테스트 스위트를 검색하고, 각 테스트 클래스별로 tester-agent 태스크를 병렬 생성합니다. 스위트 전체를 한 번에 실행하는 대신 클래스 단위로 분리하여 태스크를 만들 때 사용합니다.

- **`/agents:verify <uitest_results.json 경로>`**  
  verifier-agent 태스크를 생성하여, 실패한 UI 테스트를 실제 기기에서 검증합니다.

### 2.5 지원 플랫폼

- **Android**: `./gradlew connectedDebugAndroidTest`, 파싱 스크립트 `bin/parse-android-test-results.py`
- **iOS**: `xcodebuild test`, `.xcresult` bundle 파싱

---

## 3. 상세 내용

### 3.1 디렉터리 구조

```
.gemini/
├── agents/
│   ├── tasks/          # 태스크 JSON (상태, pending/running/complete)
│   ├── plans/          # 에이전트 장기 계획용 마크다운
│   ├── logs/           # 에이전트 실행 로그, uitest_results.json, device_verification.json
│   └── workspace/      # 실제 테스트 대상 프로젝트 (Android/iOS)
├── commands/
│   └── agents/         # /agents:* 커맨드 정의 (.toml)
├── extensions/
│   ├── tester-agent/   # UI 테스트 실행 에이전트
│   └── verifier-agent/ # 실패 테스트 기기 검증 에이전트
bin/
├── parse-android-test-results.py   # JUnit XML → uitest_results.json
├── run-agent-with-retry.sh         # 모델 용량 오류 시 재시도
└── reconcile-tasks.sh             # 실패/완료 태스크 상태 정합
```

### 3.2 커맨드 목록

| 커맨드 | 설명 |
|--------|------|
| `/agents:start <agent_name> "<prompt>"` | 태스크 생성 (tasks 디렉터리에 JSON 파일) |
| `/agents:test-planing` | CriticalRT 스위트 검색 후 클래스별 tester-agent 태스크 병렬 생성 |
| `/agents:run [task_id]` | 대기 중인 태스크 실행 (백그라운드 실행) |
| `/agents:status [task_id \| status]` | 태스크 상태 조회 (재정합 후 표시) |
| `/agents:verify <uitest_results.json_path>` | verifier-agent 태스크 생성 (실패 UI 테스트 검증) |
| `/agents:type` | 사용 가능한 에이전트 확장 목록 |

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

**1. UI 테스트 태스크 생성 및 실행**

```bash
# 방법 A: 수동으로 프롬프트 지정
gemini /agents:start tester-agent "CriticalRTSuite 전체 실행"
gemini /agents:run

# 방법 B: CriticalRT 스위트 클래스별 태스크 자동 생성 (병렬 실행에 유리)
gemini /agents:test-planing
gemini /agents:run   # 대기 중인 태스크들을 순차 실행
```

**2. 상태 확인**

```bash
gemini /agents:status
```

**3. 실패 테스트 검증 (verifier-agent)**

```bash
gemini /agents:verify .gemini/agents/logs/task_1708499261_8_uitest_results.json
gemini /agents:run
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

### 3.8 추후 방향: End-to-End UITest 파이프라인

**목표 파이프라인**

```
test-planing → testing → verify → coding(테스트코드 수정) → PR 생성
     │            │         │            │                    │
     │            │         │            │                    └─ pr-agent (또는 reviewer-agent + git)
     │            │         │            └─ coder-agent (verifiedFailures 기반 수정)
     │            │         └─ verifier-agent (device_verification.json)
     │            └─ tester-agent (uitest_results.json)
     └─ CriticalRT 스위트 → 클래스별 태스크 생성
```

**현재 진행 상황**

| 단계 | 상태 | 비고 |
|------|------|------|
| test-planing | ✅ 완료 | `/agents:test-planing` |
| testing | ✅ 완료 | tester-agent, `uitest_results.json` |
| verify | ✅ 완료 | `/agents:verify`, verifier-agent, `device_verification.json` |
| coding (테스트코드 수정) | ⚠️ 미연결 | coder-agent 존재하나 `device_verification.json` → 태스크 자동 생성 없음 |
| PR 생성 | ❌ 미구현 | PR 에이전트/커맨드 없음 |

**향후 필요 작업**

1. **`/agents:fix` (또는 `/agents:code`) 커맨드 추가**
   - 입력: `device_verification.json` 경로
   - 동작: `verifiedFailures` 항목을 읽어 coder-agent 태스크 생성. 프롬프트에 `className`, `testName`, `errorMessage`, `testFilePath`, `verificationNote` 포함
   - coder-agent 페르소나: 기존 테스트 파일 **수정** 지원 (현재는 "새 파일 생성" 위주). `workspace` 내 기존 파일 편집 허용

2. **coder-agent UITest 수정 워크플로우 정교화**
   - `device_verification.json` 형식에 맞는 수정 지시 구조화
   - Espresso/UI 테스트 실패 패턴(NoMatchingViewException 등)에 대한 수정 가이드라인을 페르소나에 반영

3. **PR 생성 단계**
   - 옵션 A: `pr-agent` 익스텐션 추가. Git 브랜치 생성 → 커밋 → PR 생성 (GitHub/GitLab API 또는 CLI)
   - 옵션 B: reviewer-agent 확장. 코드 리뷰 후 `gh pr create` 등 셸 명령으로 PR 생성
   - 필요: `settings.json` 또는 익스텐션에 저장소 URL, 브랜치 네이밍 규칙 설정

4. **파이프라인 자동화 (선택)**
   - `/agents:pipeline` 또는 워크플로우 스크립트: test-planing → run(반복) → verify → fix → run → pr
   - 각 단계 완료 시 다음 단계 트리거 조건 정의 (예: `verifiedFailures` 비어 있으면 PR로, 있으면 fix로)

### 3.9 참고 자료

- **블로그**: [How I Turned Gemini CLI into a Multi-Agent System with Just Prompts](https://aipositive.substack.com/p/how-i-turned-gemini-cli-into-a-multi)
- **데모 비디오**: [See it in Action](https://aipositive.substack.com/i/169284045/see-it-in-action)
- **Anthropic**: [Building a Sub-Agent with Claude](https://docs.anthropic.com/en/docs/claude-code/sub-agents)
- **Gemini CLI 로드맵**: [공식 에이전트 기능 이슈](https://github.com/google-gemini/gemini-cli/issues/4168)

---

## Disclaimer

이 프로젝트는 **proof-of-concept** 실험입니다. 프로덕션 환경에서의 사용은 권장하지 않으며, `-y` 플래그 사용 시 보안 검증이 우회됩니다.
