# MCP Setup — mobile-mcp 연동 가이드

`uitest-loop` skill 은 AI Verify 단계에서 [`mobile-mcp`](https://github.com/mobile-next/mobile-mcp) MCP 서버를 통해 실단말에서 UI 시나리오를 재현한다.

Claude Code **Skill 단독으로는 MCP 서버를 자동 등록할 수 없다** (공식 스펙 상 `SKILL.md` frontmatter 에 MCP 의존성 필드가 없음). 따라서 아래 중 한 가지 방법으로 MCP 를 등록해야 한다.

| 상황 | 추천 방법 | 자동화 정도 |
|---|---|---|
| 지금 바로 skill 만 써보고 싶다 | **A. 수동 등록** | 사용자 1회 수동 |
| 이미 운용 중인 사내 **기존 플러그인** 이 있다 | **B. 기존 플러그인에 skill 편입** | 플러그인 설치만으로 자동 |
| 새 **배포 채널** 로 나눠 관리하고 싶다 | **C. 신규 플러그인 생성** | 플러그인 설치만으로 자동 |

---

## A. 수동 등록 (현재 기본 경로)

### A-1. 프로젝트 레벨 `.mcp.json`

프로젝트 루트에 `.mcp.json` 을 생성하거나 기존 파일에 다음 블록을 추가:

```json
{
  "mcpServers": {
    "mobile-mcp": {
      "command": "npx",
      "args": ["-y", "@mobilenext/mobile-mcp@latest"]
    }
  }
}
```

- 프로젝트 팀원 전부가 공유하므로 커밋 권장.
- 사내 mirror / 고정 버전이 있다면 `@latest` 대신 특정 버전 고정.

### A-2. 사용자 레벨 (본인만)

```bash
claude mcp add mobile-mcp -- npx -y @mobilenext/mobile-mcp@latest
```

또는 `~/.claude.json` 의 `mcpServers` 에 위와 동일한 엔트리를 직접 추가.

### A-3. 등록 확인

Claude Code 세션에서:

```
/mcp
```

`mobile-mcp` 가 `connected` 로 보이면 준비 완료. skill 실행 시 `mcp__mobile-mcp__*` 툴 호출이 가능하다.

### A-4. MCP 없이 skill 쓰기

실단말 재현이 불필요하거나 MCP 등록이 어려운 경우:

```
/uitest-loop --skip-verify
```

`failedTests` 전체가 그대로 `verifiedFailures` 로 취급되어 코드 수정 단계로 진입한다.

---

## B. 기존 플러그인에 편입

이미 내부 배포 중인 Claude Code 플러그인이 있다고 가정한다. 예시 구조:

```
my-internal-plugin/
├── .claude-plugin/
│   └── plugin.json
├── skills/
│   └── other-skill/
│       └── SKILL.md
├── commands/...
└── (.mcp.json 있을 수도, 없을 수도)
```

### B-1. skill 디렉토리 복사

`uitest-loop/` 전체를 플러그인의 `skills/` 하위로 이동:

```
my-internal-plugin/
└── skills/
    ├── other-skill/
    └── uitest-loop/        ← 여기로 이동
        ├── SKILL.md
        ├── scripts/
        ├── hooks/
        └── references/
```

> skill 내부에서 참조하는 `${CLAUDE_SKILL_DIR}` 는 플러그인 컨텍스트에서도 자동으로 해당 skill 디렉토리로 치환되므로 **수정 불필요**.

### B-2. `.mcp.json` 병합

플러그인 **루트**의 `.mcp.json` 에 `mobile-mcp` 서버 엔트리를 추가.

- 이미 파일이 있는 경우: `mcpServers` 객체에 키를 한 줄 추가.
- 파일이 없는 경우: 새로 생성.

```json
{
  "mcpServers": {
    "existing-server": { "...기존 유지": true },
    "mobile-mcp": {
      "command": "npx",
      "args": ["-y", "@mobilenext/mobile-mcp@latest"]
    }
  }
}
```

### B-3. `plugin.json` 확인

별도 수정은 필요 없지만, 버전 범프를 권장:

```json
{
  "name": "my-internal-plugin",
  "version": "1.4.0",
  "description": "... + uitest-loop skill with mobile-mcp"
}
```

### B-4. 배포 & 사용자 업데이트 유도

- 플러그인 marketplace / git 저장소에 push.
- 사용자는 `/plugin update my-internal-plugin` (또는 재설치) 로 받자마자 **skill + MCP 설정이 함께 자동 반영**된다.
- 사용자가 기존에 수동 등록해둔 `mobile-mcp` 가 있다면 프로젝트/사용자 레벨 설정이 플러그인보다 우선되므로 충돌은 발생하지 않음. 중복 제거를 위해 기존 등록은 정리 권장.

### B-5. skill 호출 네임스페이스

플러그인으로 배포된 skill 은 다음 형태로 호출된다:

```
/my-internal-plugin:uitest-loop --class com.example.FooTest
```

자동 로드 (description 매칭 기반 invocation) 는 동일하게 동작.

---

## C. 신규 플러그인 생성

기존 플러그인이 없거나 별도 채널로 관리하고 싶다면 독립 플러그인을 새로 만든다.

### C-1. 디렉토리 스캐폴드

```
uitest-loop-plugin/
├── .claude-plugin/
│   └── plugin.json
├── .mcp.json
└── skills/
    └── uitest-loop/        ← 현재 skill 을 통째로 이동
        ├── SKILL.md
        ├── scripts/
        ├── hooks/
        └── references/
```

### C-2. `plugin.json`

```json
{
  "name": "uitest-loop",
  "version": "0.1.0",
  "description": "Android/iOS UI test autoloop: run → AI verify via mobile-mcp → fix → re-run",
  "author": {
    "name": "<팀/이메일>"
  },
  "keywords": ["android", "ios", "uitest", "xcuitest", "mobile-mcp"]
}
```

### C-3. `.mcp.json`

```json
{
  "mcpServers": {
    "mobile-mcp": {
      "command": "npx",
      "args": ["-y", "@mobilenext/mobile-mcp@latest"]
    }
  }
}
```

> 플러그인 설치 시 이 엔트리가 사용자의 MCP 설정에 자동 병합된다. 사용자는 별도 `claude mcp add` 가 필요 없다.

### C-4. 배포 옵션

**(a) Git 저장소 직접 설치 (사내 배포에 적합)**

```bash
claude plugin install <org>/uitest-loop-plugin
# 또는
claude plugin install https://github.com/<org>/uitest-loop-plugin
```

**(b) Marketplace 등록**

사내 marketplace 가 있다면 `marketplace.json` 에 엔트리 추가 후 push.

**(c) 로컬 검증**

```bash
claude plugin install ./uitest-loop-plugin   # 로컬 경로
```

### C-5. 업데이트 운영

- 버전 업 시 `plugin.json` 의 `version` 만 올리면 됨.
- skill 내부 스크립트 (`scripts/*.sh`) 변경은 자동 반영.
- 호환성 깨는 변경은 MAJOR 버전 올리고 README 에 마이그레이션 안내.

---

## 체크리스트 (배포 전)

- [ ] `.mcp.json` 이 유효한 JSON (trailing comma 없음)
- [ ] `mobile-mcp` 를 설치하지 않은 깨끗한 환경에서 플러그인 설치 → `/mcp` 로 자동 등록 확인
- [ ] `/uitest-loop --dry-run` 실행 시 에러 없이 계획 출력
- [ ] `/uitest-loop --skip-verify` 동작 (MCP 없이도 fallback 가능)
- [ ] SKILL.md 의 `description` 키워드로 자동 invocation 매칭 확인

---

## 참고 링크

- Claude Code Skills: https://docs.claude.com/en/docs/claude-code/skills
- Claude Code Plugins: https://docs.claude.com/en/docs/claude-code/plugins
- Claude Code MCP: https://docs.claude.com/en/docs/claude-code/mcp
- mobile-mcp 저장소: https://github.com/mobile-next/mobile-mcp
