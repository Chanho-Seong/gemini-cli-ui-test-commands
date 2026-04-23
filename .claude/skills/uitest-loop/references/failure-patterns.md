# UI Test 실패 패턴 → 근본 원인 → 수정 전략

코드 수정(fix) 단계에서 참조한다. 각 플랫폼별로 에러 메시지 → 원인 → 최소 수정(minimal fix) 전략.

## Android (Espresso / Compose)

| Error Pattern | Root Cause | Fix Strategy |
|---|---|---|
| `No views in hierarchy found matching: with id: R.id.xxx` | 리소스 ID 가 잘못되었거나 제거됨 | `grep -r "xxx\|<유사이름>" <project>/*/src/main/res/layout/ --include="*.xml" -l` 로 실제 ID 확인 후 매처 업데이트 |
| `View is not present in the hierarchy` | 렌더링 전에 assert | `check(matches(isDisplayed()))` 또는 `IdlingResource` 로 대기 |
| `AmbiguousViewMatcherException` | 여러 뷰가 매칭 | `allOf(withId(...), isDescendantOfA(withId(<parent>)))` 로 축소 |
| `Expected: is "X" but: was "Y"` | 텍스트 assertion mismatch | `strings.xml` 확인 후 expected 값 업데이트 |
| `NullPointerException in @Before` | Rule/setup 누락 | `HiltAndroidRule`, `createAndroidComposeRule` 등 필요한 rule 확인 |
| `PerformException: Error performing X on view` | 뷰가 obscured/off-screen | `scrollTo()` 후 `click()` |
| `RecyclerView: No view holder at position X` | 리스트 미로드 | `scrollToPosition(X)` 추가 |
| `TimeoutException` | 비동기 작업 미완료 | `IdlingResource` 등록 또는 timeout 증가. `Thread.sleep` 은 금지 |
| `ClassCastException` | 잘못된 뷰 타입 매처 | 올바른 뷰 타입 매처 사용 |
| Compose: `No node matching (hasTestTag("x"))` | testTag 오탈자 또는 미부착 | `grep` 으로 실제 testTag 값 확인 후 갱신 |

### Compose 권장 매처 순서
1. `onNodeWithTag("feature_component")` — **최우선**
2. `onNodeWithText("...")`
3. `onNodeWithContentDescription("...")`
4. 복합: `onNode(hasTestTag("x") and hasText("y"))`

---

## iOS (XCUITest)

| Error Pattern | Root Cause | Fix Strategy |
|---|---|---|
| `Failed to find matching element` | accessibility identifier 오탈자 | UI 계층에서 실제 id 확인 후 업데이트 |
| `No matches found for Element` | 네비게이션 미완료 | `.exists` 대신 `.waitForExistence(timeout: 5)` |
| `Value assertion failed` | 텍스트/값 mismatch | 실제 값 확인 후 assertion 업데이트 |
| `Element is not hittable` | 뷰가 가려짐/화면 밖 | `swipeUp()` 으로 스크롤 또는 가시성 대기 |
| `XCTAssertEqual failed` | 상태 mismatch | `setUp()` 의 launchArguments / 초기 상태 확인 |
| `Scene never became active` | 스킴/환경 설정 문제 | 테스트 플랜 / launchArguments 확인 |

### XCUITest 권장 요소 접근 순서
1. `app.buttons[AccessibilityID.submitButton]` — **최우선**
2. `app.buttons["제출"]` (accessibility label)
3. `app.buttons.element(boundBy: 0)` — 금지 (fragile)

### 비동기 대기 필수 패턴
```swift
let element = app.buttons[ID.submitButton]
XCTAssert(element.waitForExistence(timeout: 5))   // NOT just .exists
```

---

## 공통 원칙 (수정 시 반드시)

1. **Assertion 을 제거하지 마라** — expected 값을 올바르게 갱신하거나 매처를 보정하라.
2. **테스트 의도를 바꾸지 마라** — 같은 사용자 행위를 검증해야 한다.
3. **우선 테스트 코드를 고쳐라** — 프러덕 코드는 "테스트가 정확한데 실제 버그가 있다" 고 판명된 경우만.
4. **리소스를 직접 찾아라** — `grep` 으로 실제 ID / 문자열 / testTag 값을 확인한 뒤 반영.
5. **컴파일 체크** — 수정 후 반드시 컴파일만이라도 검증:
   - Android: `./gradlew :<module>:compile<Variant>AndroidTestSources`
   - iOS: `xcodebuild build-for-testing ...`
6. **최소 변경 커밋** — className 단위로 atomic commit. 메시지 형식: `fix(uitest): <ClassName> - <brief cause>`
