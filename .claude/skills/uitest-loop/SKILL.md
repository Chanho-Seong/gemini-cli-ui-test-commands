---
name: uitest-loop
description: Android/iOS UI 테스트의 검증 루프(run → AI verify → fix → re-run)를 자동 수행한다. connectedAndroidTest 또는 xcodebuild test로 실행하고, mobile-mcp 로 실단말에서 시나리오를 재현해 검증한 뒤, 컨벤션에 맞춰 테스트/프러덕 코드를 수정하고 재실행까지 수행한다. "UI 테스트 검증 루프", "UI 테스트 고쳐줘", "실패한 instrumentation 테스트 분석", "uitest 루프", "xcuitest 자동 수정", "connectedAndroidTest 실패 자동 복구" 같은 요청에 사용.
argument-hint: "[--class <fqn>]... [--suite <fqn>] [--method <test>] [--variant <name>] [--module <name>] [--device <id>] [--skip-verify] [--max-iterations <n>] [--dry-run]"
allowed-tools: Bash Read Edit Grep Glob mcp__mobile-mcp__*
---

# UI Test Loop — 실행 가이드

당신의 목표는 현재 작업 디렉토리의 Android 또는 iOS 프로젝트에서 UI 테스트 실패를 자동으로 진단·수정하고, 고친 뒤 재실행까지 수행해 최종 리포트를 출력하는 것이다.

산출물은 모두 **메인 모듈의 `build/ai-uitest/` 하위**에 저장되며, 각 단계 종료 시 데스크탑 알림이 발행된다.

## 의존성 (MCP)

이 skill 은 **AI Verify 단계**에서 `mobile-mcp` MCP 서버를 사용해 실단말 시나리오를 재현한다. Skill 자체로는 MCP 를 자동 설치하지 않으므로, 사용 전에 `mobile-mcp` 가 이미 등록되어 있어야 한다.

- 미등록 상태로 skill 을 실행하면 `mcp__mobile-mcp__*` 호출이 실패한다. 이 때 AI Verify 를 건너뛰려면 `--skip-verify` 로 재호출.
- `allowed-tools` 에 `mcp__mobile-mcp__*` 와일드카드를 포함하여 verify 단계의 반복 승인 프롬프트를 방지한다. 단말 고정은 1번 단계에서 이미 사용자가 확인하므로 중복 승인이 되지 않도록 한 것이다.
- 수동 등록 방법 및 플러그인 배포 시 자동 등록 방법은 **[references/mcp-setup.md](references/mcp-setup.md)** 참조.

## Arguments

`$ARGUMENTS` 에서 다음을 파싱한다 (전부 선택):
- `--class <FQCN>` — 실행할 테스트 클래스. 복수 지정 가능 (반복 flag).
- `--suite <FQCN>` — 테스트 스위트 (`@RunWith(Suite.class)` / iOS test plan).
- `--method <name>` — 특정 테스트 메서드. `--class` 없이 단독 사용해도 된다 — 스크립트가 `androidTest`/UITests 소스를 스캔해 해당 메서드가 속한 클래스를 자동 감지한다. 동일 이름 메서드가 여러 클래스에 존재해 모호하면 감지 실패로 중단하므로, 그 경우에만 `--class` 를 함께 지정한다.
- `--variant <name>` — Android buildVariant (기본: `debug`).
- `--module <name>` — Android Gradle 모듈명. 미지정 시 `settings.gradle*` 에서 `com.android.application` 적용 모듈을 자동 감지.
- `--device <id>` — 사용할 디바이스 id (Android adb serial, iOS UDID). 미지정 시 기존 pin 재사용 또는 사용자 확인.
- `--skip-verify` — AI Verify 단계 스킵 (실단말 재현 없이 바로 fix 로 진행).
- `--max-iterations <N>` — 재테스트 실패 시 자동 분석·수정·재테스트 반복 횟수 상한. 기본 `3`. `1` 이면 루프 없이 한 번만 수행 (기존 단발 동작과 동일). 1차 실행은 카운트하지 않으며, 첫 fix→retest 사이클이 iteration 1 이다.
- `--dry-run` — 실제 실행 없이 계획만 출력.

**중요:** `--class` / `--suite` / `--method` 가 지정되면 **1차 실행, Verify, 재테스트 모두 동일한 필터 범위 내**에서만 동작해야 한다. 지정 범위 밖으로 실행을 확장하지 말 것.

---

## 실행 플로우 (반드시 순서대로)

### 0. 환경 준비

플랫폼/메인모듈/빌드 디렉토리를 감지하고 환경 변수로 보관한다.

```bash
eval "$(bash ${CLAUDE_SKILL_DIR}/scripts/detect-platform.sh)"
BUILD_DIR="$(bash ${CLAUDE_SKILL_DIR}/scripts/resolve-build-dir.sh ${MODULE_ARG:-})"
export BUILD_DIR PLATFORM MAIN_MODULE
mkdir -p "$BUILD_DIR/logs" "$BUILD_DIR/screenshots" "$BUILD_DIR/retest" "$BUILD_DIR/state"
bash ${CLAUDE_SKILL_DIR}/scripts/ensure-gitignore.sh "$BUILD_DIR"
```

**노티 정책:** 환경 준비(0)·디바이스 확인(1)·`--dry-run` 분기(2) 같은 **테스트 환경 설정 단계에서는 `notify-step.sh` 를 호출하지 않는다.** 데스크탑 알림은 실제 작업 결과가 나오는 3단계(1차 테스트) 이후부터 발행한다.

`PLATFORM` 이 `unknown` 이면 에러 메시지와 함께 중단하고 사용자에게 경로 확인을 요청한다.

### 1. 디바이스 확인 / 고정

- `--device <id>` 가 지정된 경우:
  ```bash
  bash ${CLAUDE_SKILL_DIR}/scripts/device-select.sh pin "$PLATFORM" "<id>" --build-dir "$BUILD_DIR"
  ```
- 미지정인 경우 기존 핀을 재사용:
  ```bash
  CURRENT_DEVICE="$(bash ${CLAUDE_SKILL_DIR}/scripts/device-select.sh current --build-dir "$BUILD_DIR" 2>/dev/null || echo '')"
  ```
- 핀이 없으면 디바이스 목록을 조회하고 **사용자에게 선택 요청**:
  ```bash
  bash ${CLAUDE_SKILL_DIR}/scripts/device-select.sh list "$PLATFORM"
  ```
  목록이 1개뿐이면 그 디바이스를 자동 pin. 2개 이상이면 사용자에게 "어떤 디바이스를 사용하시겠습니까?" 라고 확인한 뒤 선택값을 pin.
- 최종 `CURRENT_DEVICE` 를 이후 모든 단계에서 `--device` 인자로 전달한다.

### 2. `--dry-run` 분기

`--dry-run` 이면 run-test-*.sh 를 `--dry-run` 으로 호출하여 계획만 출력하고 종료.

### 3. 1차 테스트 실행

**테스트 필터 (--class/--suite/--method) 를 정확히 전달한다.**
**중요:** Bash 툴 호출 시 **반드시 한 줄**로 작성한다. 다중 라인 `\` 연결은 쓰지 말 것 (툴 실행 중 분해되어 실패).

**Android variant 처리:**
- 사용자가 `$ARGUMENTS` 에 `--variant <name>` 을 넘긴 경우 → **반드시 그대로 `--variant "$VARIANT"` 인자로 전달**해야 한다. 누락 시 자동 감지 결과가 사용자 지정값과 달라질 수 있음.
- `--variant` 가 없으면 스크립트가 `<module>/build.gradle*` 을 파싱해 `productFlavors + buildTypes` 조합을 추정하고 **debug 우선** 으로 자동 선택한다. 첫 호출에서 바로 올바른 variant (예: `googleDebug`) 를 찾으므로 실패 → 변경 재시도 루프를 돌리지 말 것.

감지 결과가 의심스러우면 다음 명령으로 후보를 먼저 확인:
```
bash "${CLAUDE_SKILL_DIR}/scripts/detect-variants.sh" --module "$MAIN_MODULE" --fast
```

Android (예시 — 인자 순서 자유, 필요 시 반복). 사용자가 `--variant` 를 지정한 경우 반드시 포함:
```
bash "${CLAUDE_SKILL_DIR}/scripts/run-test-android.sh" --output-dir "$BUILD_DIR/logs" --module "$MAIN_MODULE" --variant "$VARIANT" --device "$CURRENT_DEVICE" --project-path "." --class com.example.FooTest
```
`--variant` 가 `$ARGUMENTS` 에 없으면 해당 토큰만 생략한다 (자동 감지에 위임).
이후 단계(재테스트/컴파일 체크)에서 동일 값을 재사용하려면, 1차 실행 시 스크립트 로그(`[run-test-android] Auto-detected variant: ...`)에서 확정된 값을 `VARIANT` 환경변수에 저장해 두고 사용한다.

iOS:
```
bash "${CLAUDE_SKILL_DIR}/scripts/run-test-ios.sh" --output-dir "$BUILD_DIR/logs" --device "$CURRENT_DEVICE" --project-path "." --class MyAppUITests/LoginTest
```

**단일 디바이스 전제:** `--device "$CURRENT_DEVICE"` 가 지정된 상태이므로 스크립트는 **샤딩 없이** 해당 단말에서 단일 `am instrument` 실행으로 돌린다. 여러 단말을 병렬 활용할 필요가 있으면 `--device` 를 생략하면 되지만, 이 skill 의 기본 동작은 pin 된 1대만 사용.

결과: `$BUILD_DIR/logs/all_uitest_results.json` — `selectionFilter` 필드에 지정 인자가 기록됨.

```bash
FAILED=$(python3 -c "import json; print(json.load(open('$BUILD_DIR/logs/all_uitest_results.json'))['failedCount'])")
bash ${CLAUDE_SKILL_DIR}/scripts/notify-step.sh tests-done "실패 ${FAILED}건"
```

`FAILED == 0` 이면 **바로 8번(최종 리포트)** 로 점프.

### 4. AI Verify (실단말 재현)

`--skip-verify` 이면 이 섹션 전체를 건너뛰고 `failedTests` 를 그대로 `verifiedFailures` 로 간주하여 `$BUILD_DIR/logs/device_verification.json` 에 작성 후 다음 단계로.

그 외:
1. `$BUILD_DIR/logs/all_uitest_results.json` 의 `failedTests` 를 **모두** 순회 (필터 범위 내).
2. 각 테스트에 대해:
   - `Read` 로 테스트 소스 파일을 찾아 읽고 시나리오 (클릭/입력/assertion) 를 추출.
   - mobile-mcp 로 `CURRENT_DEVICE` 에서 앱을 실행하고 시나리오를 재현.
     - `mcp__mobile-mcp__mobile_list_available_devices` 로 디바이스 확인.
     - `mcp__mobile-mcp__mobile_launch_app` (Android: package, iOS: bundle id).
     - `mcp__mobile-mcp__mobile_list_elements_on_screen` → 좌표 파악 후 `mobile_click_on_screen_at_coordinates` / `mobile_type_keys` / `mobile_swipe_on_screen` 로 조작.
     - 핵심 시점마다 `mcp__mobile-mcp__mobile_take_screenshot` → 파일을 `$BUILD_DIR/screenshots/<className>_<testName>.png` 로 저장.
   - 판정:
     - 실제로 실패 재현 → `verifiedFailures` 에 추가.
     - 다른 경로로 동일 목적 달성 가능 → `verifiedPasses` 에 추가 (환경차로 판명).
3. 결과 스키마:
   ```json
   {
     "platform": "<android|ios>",
     "deviceId": "<id>",
     "projectPath": ".",
     "verifiedFailures": [
       {"className":"...","testName":"...","errorMessage":"...","stackTrace":"...","testFilePath":"...","deviceResult":"FAILED","verificationNote":"..."}
     ],
     "verifiedPasses": [
       {"className":"...","testName":"...","deviceResult":"PASSED","verificationNote":"대체 경로로 성공"}
     ]
   }
   ```
4. `$BUILD_DIR/logs/device_verification.json` 으로 저장.

```bash
VF=$(python3 -c "import json; print(len(json.load(open('$BUILD_DIR/logs/device_verification.json'))['verifiedFailures']))")
VP=$(python3 -c "import json; print(len(json.load(open('$BUILD_DIR/logs/device_verification.json'))['verifiedPasses']))")
bash ${CLAUDE_SKILL_DIR}/scripts/notify-step.sh verify-done "실제 실패 ${VF}건 / 환경차 ${VP}건"
```

`verifiedFailures` 가 비어 있으면 8번(최종 리포트)로 점프 — 모두 환경 문제였음.

### 5. 코드 수정

**먼저 컨벤션과 실패 패턴 문서를 반드시 읽는다:**
- Android: `Read` `${CLAUDE_SKILL_DIR}/references/android-uitest-conventions.md`
- iOS: `Read` `${CLAUDE_SKILL_DIR}/references/ios-uitest-conventions.md`
- 공통: `Read` `${CLAUDE_SKILL_DIR}/references/failure-patterns.md`

그 후 `verifiedFailures` 를 **className 단위로 그룹화** 하여 순차 처리:

각 className 에 대해:
1. 테스트 소스 `Read`.
2. 에러 메시지 + stackTrace 를 failure-patterns.md 의 매핑 표와 대조.
3. 실제 리소스 값을 `Grep` 으로 확인:
   - Android resource id: `grep -r "R.id.xxx\|<유사이름>" <project>/src/main/res/layout/ --include="*.xml"`
   - 문자열: `grep -r "<text>" <project>/src/main/res/values/ --include="strings*.xml"`
   - Compose testTag: `grep -r "testTag(\"xxx\")" <project>/src/main/java <project>/src/main/kotlin`
   - iOS accessibilityIdentifier: `grep -r "accessibilityIdentifier = \"xxx\"" <project>`
4. **최소 수정 (minimal fix)** 을 `Edit` 으로 적용:
   - 매처 교체, waitForExistence 추가, scrollTo() 추가 등.
   - Assertion 제거 / 테스트 의도 변경 절대 금지.
   - 테스트 코드를 먼저 고치고, 명백히 프러덕 버그일 때만 prod 코드 수정.
5. **컴파일 체크** (실패하면 해당 className 의 수정 파일만 rollback 후 다른 수정 시도):
   - Android:
     ```bash
     ./gradlew ":${MAIN_MODULE}:compile$(printf '%s\n' "${VARIANT:-Debug}" | sed 's/.*/\u&/')AndroidTestSources" 2>&1 | tee -a "$BUILD_DIR/logs/compile-check.log"
     ```
   - iOS:
     ```bash
     xcodebuild build-for-testing -workspace <ws> -scheme <scheme> -destination "id=$CURRENT_DEVICE" 2>&1 | tee -a "$BUILD_DIR/logs/compile-check.log"
     ```
   - rollback: 커밋이 없는 상태이므로 `git restore --source=HEAD --worktree -- <files>` 로 작업 트리만 HEAD 로 복원한다 (스테이지/커밋 조작 금지).

**중요:** 이 단계에서는 **`git add` / `git commit` 을 절대 수행하지 않는다.** 모든 commit 은 7단계(검토/커밋)에서 일괄 수행된다. 작업 트리는 dirty 상태로 남겨 두고 다음 단계로 진행한다.

**모든 className 처리 후** `$BUILD_DIR/logs/fix_report.json` 작성:
```json
{
  "taskId": "",
  "projectPath": ".",
  "status": "completed|needs_review",
  "iterations": 0,
  "maxIterations": 3,
  "filesModified": ["path/A.kt", "path/B.kt"],
  "fixedTests": [
    {"className":"...","testName":"...","iteration":1,"rootCause":"...","fixApplied":"...","commitHash":""}
  ]
}
```

`commitHash` 는 7단계 commit 실행 후에 채워지므로 5단계 시점에서는 빈 문자열로 둔다. `iterations` 와 `maxIterations` 도 5단계에서는 각각 `0` / `--max-iterations` 값으로 초기화하고, 6단계 루프에서 갱신한다.

```bash
MODIFIED=$(python3 -c "import json; print(len(json.load(open('$BUILD_DIR/logs/fix_report.json'))['filesModified']))")
FIXED=$(python3 -c "import json; print(len(json.load(open('$BUILD_DIR/logs/fix_report.json'))['fixedTests']))")
bash ${CLAUDE_SKILL_DIR}/scripts/notify-step.sh fix-done "파일 ${MODIFIED}개 / 테스트 ${FIXED}건 수정"
```

### 6. 재테스트 루프 (iteration)

**재실행 범위 규칙**:
- 사용자가 원래 `--suite`/`--method`/`--class` 를 지정했다면 → **동일 인자 그대로 재적용**.
- 지정이 없었다면 → `fix_report.json` 에서 수정된 className 만 모아 `--class` 반복 전달.

- 디바이스는 모든 iteration 에서 동일 `CURRENT_DEVICE` 사용.
- iteration 별 출력 디렉토리: `$BUILD_DIR/retest/iter-<N>/`.
- 마지막 iteration 의 결과는 `$BUILD_DIR/retest/all_uitest_results.json` 으로도 복사하여 8단계 리포트가 일관되게 읽도록 한다.

**iteration 루프 흐름** (`MAX_ITER` 는 `--max-iterations` 값, 기본 3):

```
ITER=1
MAX_ITER=${MAX_ITERATIONS:-3}

while True:
  RETEST_DIR="$BUILD_DIR/retest/iter-$ITER"
  mkdir -p "$RETEST_DIR"

  # 6.1 재테스트 실행 (반드시 단일 라인, multi-line `\` 금지)
  #   variant 는 1차에서 확정된 $VARIANT 를 그대로 명시 전달.
  Android:
    bash "${CLAUDE_SKILL_DIR}/scripts/run-test-android.sh" --output-dir "$RETEST_DIR" --module "$MAIN_MODULE" --variant "$VARIANT" --device "$CURRENT_DEVICE" --class com.example.FooTest
  iOS:
    bash "${CLAUDE_SKILL_DIR}/scripts/run-test-ios.sh" --output-dir "$RETEST_DIR" --device "$CURRENT_DEVICE" --class MyAppUITests/LoginTest

  # 6.2 결과 집계
  RFC=$(python3 -c "import json; print(json.load(open('$RETEST_DIR/all_uitest_results.json'))['failedCount'])")
  RPC=$(python3 -c "import json; print(json.load(open('$RETEST_DIR/all_uitest_results.json'))['passedCount'])")
  bash ${CLAUDE_SKILL_DIR}/scripts/notify-step.sh retest-done "iter ${ITER}: 통과 ${RPC} / 실패 ${RFC}"

  # fix_report.json 의 iterations 카운트 업데이트
  jq --argjson n "$ITER" '.iterations = $n' "$BUILD_DIR/logs/fix_report.json" > "$BUILD_DIR/logs/fix_report.json.tmp" \
    && mv "$BUILD_DIR/logs/fix_report.json.tmp" "$BUILD_DIR/logs/fix_report.json"

  # 6.3 종료 조건
  if RFC == 0:
      fix_report.json#status = "completed"
      cp "$RETEST_DIR/all_uitest_results.json" "$BUILD_DIR/retest/all_uitest_results.json"
      break  → 7단계로

  if ITER >= MAX_ITER:
      fix_report.json#status = "needs_review"
      cp "$RETEST_DIR/all_uitest_results.json" "$BUILD_DIR/retest/all_uitest_results.json"
      break  → 7단계로 (검토 시 사용자에게 경고 출력)

  # 6.4 잔여 실패 분석 (iteration 계속)
  - $RETEST_DIR/all_uitest_results.json 의 failedTests 를 모두 읽어 errorMessage + stackTrace 분석.
  - failure-patterns.md 와 다시 대조.
  - 필요 시 mobile-mcp 로 현재 단말 상태 재확인:
      mcp__mobile-mcp__mobile_take_screenshot       (스크린샷을 $BUILD_DIR/screenshots/iter-${ITER}_<className>_<test>.png)
      mcp__mobile-mcp__mobile_list_elements_on_screen
    `--skip-verify` 가 켜져 있어도 이 진단용 호출은 짧게 수행해도 된다 (시나리오 전체 재현은 X).

  # 6.5 추가 수정 적용 (5단계와 동일 절차)
  - className 단위로 Read → 최소 수정 Edit → 컴파일 체크.
  - 컴파일 실패 시 git restore --source=HEAD --worktree -- <files> 로 해당 파일만 롤백 후 다른 수정 시도.
  - 변경된 파일은 fix_report.json#filesModified 에 합집합으로 추가.
  - fix_report.json#fixedTests 에 새 항목 append (각 항목에 "iteration": $ITER, "commitHash": "" 포함).
  - 이 단계에서도 git add / git commit 금지.

  ITER=$((ITER + 1))
```

`--max-iterations 1` 인 경우 첫 retest 결과로 곧바로 status 가 결정되므로 기존 단발 동작과 동일하다.

### 7. 검토 / 커밋

루프 종료 후 사용자에게 다음을 콘솔에 요약 출력한다.

1. **검토 출력**:
   - 실행한 iteration 수 / `MAX_ITER`, 최종 `status` (`completed` 또는 `needs_review`).
   - 1차 → Verify → iter1 → ... → iter${ITER} 의 passed/failed 카운트 추이.
   - 수정된 파일 목록 (`fix_report.json#filesModified`).
   - className 별 fixedTests 요약 (rootCause / fixApplied / iteration).
2. **`needs_review` 분기:** 잔여 실패가 있으면 명시 경고 후, 사용자에게 단일 확인 — "그래도 commit 을 진행할까요? (Y/N)". `N` 이면 4번을 스킵하고 8단계로.
3. **commit 실행** (status `completed` 이거나 사용자가 Y 응답):
   - `fix_report.json#fixedTests` 를 `className` 으로 group by.
   - 각 group 에 대해 다음을 단일 라인으로 실행:
     ```
     git add <해당 className 의 filesModified 만>
     git commit -m "fix(uitest): <ClassName> - <rootCause 요약 한 줄>"
     ```
   - commit hash 를 그 group 의 모든 `fixedTests[].commitHash` 에 기록.
   - **pre-commit 훅 실패 시 우회 금지** (`--no-verify` 사용 안 함). 훅 출력을 사용자에게 그대로 보고하고 중단한다.
4. **Push 안내 (자동 실행 X):** commit 종료 후 사용자에게 다음을 출력하기만 한다.
   ```
   다음 명령으로 push 하세요:
     git push                        (upstream 이 설정된 경우)
     git push -u origin <branch>     (upstream 이 없는 경우)
   ```
5. 알림: `bash ${CLAUDE_SKILL_DIR}/scripts/notify-step.sh commit-done "<created N commits>"`.

### 8. 최종 리포트

```bash
python3 ${CLAUDE_SKILL_DIR}/scripts/summary-report.py "$BUILD_DIR"
bash ${CLAUDE_SKILL_DIR}/scripts/notify-step.sh complete "리포트: $BUILD_DIR/summary.md"
```

리포트 내용을 콘솔에 출력하고 끝. 사용자에게:
- 사용된 디바이스, 테스트 범위
- 1차 / Verify / iteration 별 retest / commit 요약
- `needs_review` 항목이 있으면 명시적으로 경고
- push 가 아직 안 된 상태임을 안내 (사용자 후속 작업)

를 요약해서 보고한다.

---

## 중요 규칙

1. **Bash 툴에 전달하는 커맨드는 반드시 단일 라인** — `\` 로 라인 이어붙이기 금지. 스크립트 실행은 모든 인자를 한 줄에 나열한다.
2. **`${CLAUDE_SKILL_DIR}` 는 반드시 쌍따옴표로 감싸서 사용** — 경로 치환 실패 시 빈 문자열이 되지 않도록 `"${CLAUDE_SKILL_DIR}"` 로 쓰고, 치환 결과가 비어있다면 즉시 중단하고 사용자에게 보고.
3. **테스트 범위를 지정받으면 절대 벗어나지 말 것** — 1차·verify·재테스트 모두 동일 필터.
4. **동일 디바이스 고정 유지** — 모든 단계에서 같은 `CURRENT_DEVICE`. 기기 전환 시 반드시 사용자 승인.
5. **알림을 빠뜨리지 말 것** — 3단계(1차 테스트) 이후의 각 단계 끝에 `notify-step.sh` 호출. **테스트 환경 설정 단계(0/1/2)에서는 알림을 발행하지 않는다.**
6. **Assertion 을 지우지 말 것**, 테스트 의도를 바꾸지 말 것.
7. **pre-commit 훅 우회(`--no-verify`) 금지** — 훅 실패 시 원인 해결.
8. **산출물은 전부 `$BUILD_DIR` 하위** — 프로젝트 루트에 파일 생성 금지.
9. **5단계에서 commit 금지** — 코드 수정 단계는 작업 트리만 변경한다. 모든 `git add` / `git commit` 은 7단계(검토/커밋)에서 일괄 수행한다. 컴파일 실패 롤백은 `git restore --source=HEAD --worktree -- <files>` 만 사용.
10. **재수정 루프는 `--max-iterations` (기본 3) 까지만 자동 반복** — 상한 도달 시 `needs_review` 로 종료하고 사용자 확인을 요청한다. 사용자가 거부하면 commit 없이 작업 트리를 유지한 채 종료.
11. **Push 자동화 금지** — skill 은 `git push` 와 `gh pr create` 를 수행하지 않는다. 7단계에서 명령어만 안내한다.

## 참조 문서

- [Android UITest Conventions](references/android-uitest-conventions.md)
- [iOS UITest Conventions](references/ios-uitest-conventions.md)
- [Failure Patterns & Fix Strategy](references/failure-patterns.md)
- [MCP Setup (mobile-mcp)](references/mcp-setup.md)
