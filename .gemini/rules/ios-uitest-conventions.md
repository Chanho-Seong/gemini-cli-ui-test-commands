# iOS UITest Conventions (TCA - The Composable Architecture)

## 1. Architecture Overview (UITest 관점)

### TCA 핵심 개념

```
Feature/
  <FeatureName>Feature.swift        ← Reducer (State, Action, body 정의)
  <FeatureName>View.swift           ← SwiftUI View (Store 구독)
  <FeatureName>Client.swift         ← 외부 의존성 interface (Effect)
```

### TCA 구성 요소 요약

- **State**: 화면의 모든 상태를 담는 struct
- **Action**: 사용자 입력 및 Effect 결과를 나타내는 enum
- **Reducer**: Action을 받아 State를 변경하고 Effect를 반환
- **Store**: State와 Reducer를 연결하는 런타임 객체. View가 구독
- **Dependency**: `@Dependency` 키패스로 주입되는 외부 의존성 (네트워크, DB 등)

UITest에서는 **실제 Store를 앱과 동일하게 구동**하면서, **Dependency만 교체**하는 것이 핵심이다.

### Accessibility Identifier 관리 패턴

TCA 프로젝트에서는 보통 Feature별로 Identifier를 enum으로 관리한다:

```swift
// <FeatureName>View.swift 또는 별도 파일
enum FeatureAccessibilityID {
    static let screenRoot = "feature_screen_root"
    static let submitButton = "feature_submit_button"
    static let errorMessage = "feature_error_message"
    static let loadingIndicator = "feature_loading_indicator"
}

// View에서 적용
Button("제출") { viewStore.send(.submitTapped) }
    .accessibilityIdentifier(FeatureAccessibilityID.submitButton)
```

---

## 2. XCUITest 기본 설정

### 기본 구조

```swift
import XCTest

final class FeatureUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // 테스트용 launch argument로 Dependency 교체 지시
        app.launchArguments = ["UITestMode", "FeatureTest"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }
}
```

### TCA Dependency 교체 방법

**방법 A: Launch Argument 기반 (UITest에서 권장)**

```swift
// 앱 타겟 (AppDelegate 또는 @main)
if ProcessInfo.processInfo.arguments.contains("UITestMode") {
    // 테스트용 Dependency 오버라이드
}

// 실제 Feature 진입 시
let store = Store(initialState: FeatureReducer.State()) {
    FeatureReducer()
        .dependency(\.apiClient, .mock)   // mock dependency 주입
}
```

**방법 B: withDependencies 블록 (Unit/Integration Test 권장)**

```swift
// XCTestCase에서 직접 Store 생성 시
let store = TestStore(initialState: FeatureReducer.State()) {
    FeatureReducer()
} withDependencies: {
    $0.apiClient = .mock
    $0.userDefaults = .ephemeral()
}
```

**규칙:**
- UITest(앱 프로세스 분리)는 **Launch Argument** 방식으로 Dependency를 교체한다
- Unit/Integration Test는 `withDependencies` 블록을 사용한다
- 실제 네트워크를 호출하는 UITest는 작성하지 않는다

---

## 3. XCUITest Element 접근 규칙

### Element 탐색 우선순위

```swift
// 1순위: accessibilityIdentifier (가장 안정적)
app.buttons[FeatureAccessibilityID.submitButton]
app.staticTexts[FeatureAccessibilityID.titleLabel]

// 2순위: accessibilityLabel (사람이 읽는 텍스트)
app.buttons["제출"]

// 3순위: 타입 + 인덱스 (비권장, 깨지기 쉬움)
app.buttons.element(boundBy: 0)
```

### 자주 사용하는 Element 타입

| UI 컴포넌트 | XCUIElement 접근 |
|---|---|
| Button, .bordered, .plain | `app.buttons["id"]` |
| Text, Label | `app.staticTexts["id"]` |
| TextField | `app.textFields["id"]` |
| SecureField | `app.secureTextFields["id"]` |
| Toggle | `app.switches["id"]` |
| List Row | `app.cells["id"]` |
| NavigationBar Title | `app.navigationBars["title"]` |
| Alert | `app.alerts["title"]` |
| Sheet | `app.sheets.firstMatch` |

### 존재 및 대기 검증

```swift
// 비동기 로딩 대기 (필수 패턴)
let element = app.staticTexts[FeatureAccessibilityID.contentTitle]
XCTAssert(element.waitForExistence(timeout: 5), "콘텐츠 타이틀이 나타나지 않음")

// 즉시 존재 확인 (동기 화면 전환 후)
XCTAssertTrue(app.buttons[FeatureAccessibilityID.submitButton].exists)

// 사라짐 대기
let loading = app.activityIndicators[FeatureAccessibilityID.loadingIndicator]
XCTAssertFalse(loading.waitForExistence(timeout: 3), "로딩이 종료되지 않음")
```

**규칙:**
- 네트워크 / 비동기 처리 후 나타나는 요소는 항상 `waitForExistence(timeout:)`을 사용한다
- `timeout`은 최소 3초, 네트워크 포함 시 5초를 기본값으로 사용한다
- `.exists`만으로 검증하지 않는다 — 타이밍에 따라 false negative 발생 가능

---

## 4. TCA 기반 화면별 테스트 전략

### State 케이스별 시나리오 구성

TCA State의 각 케이스 / 조건에 대응하는 테스트를 작성한다:

```swift
// Loading 상태
func test_showsLoadingIndicator_whenFetchInProgress() {
    // Given: 응답 지연 설정
    app.launchArguments = ["UITestMode", "SlowNetwork"]
    app.launch()

    // When: 화면 진입 (자동으로 fetch 시작)
    // Then
    XCTAssert(app.activityIndicators[FeatureAccessibilityID.loadingIndicator]
        .waitForExistence(timeout: 3))
}

// Success 상태
func test_showsContent_whenFetchSucceeds() {
    app.launchArguments = ["UITestMode", "MockSuccess"]
    app.launch()

    XCTAssert(app.staticTexts[FeatureAccessibilityID.contentTitle]
        .waitForExistence(timeout: 5))
}

// Error 상태
func test_showsErrorMessage_whenFetchFails() {
    app.launchArguments = ["UITestMode", "MockError"]
    app.launch()

    XCTAssert(app.staticTexts[FeatureAccessibilityID.errorMessage]
        .waitForExistence(timeout: 5))
}
```

### Action 트리거 → 상태 전환 검증

```swift
// 버튼 탭 → 다음 화면 진입
func test_navigatesToDetail_whenItemTapped() {
    app.launchArguments = ["UITestMode", "MockListItems"]
    app.launch()

    // 리스트 아이템 대기
    let firstItem = app.cells["list_item_0"]
    XCTAssert(firstItem.waitForExistence(timeout: 5))
    firstItem.tap()

    // 상세 화면 진입 확인
    XCTAssert(app.staticTexts[DetailAccessibilityID.screenTitle]
        .waitForExistence(timeout: 3))
}

// 텍스트 입력 → 버튼 활성화
func test_enablesSubmitButton_whenFormIsValid() {
    app.launch()
    let submitButton = app.buttons[FeatureAccessibilityID.submitButton]
    XCTAssertFalse(submitButton.isEnabled)

    app.textFields[FeatureAccessibilityID.inputField].tap()
    app.textFields[FeatureAccessibilityID.inputField].typeText("유효한 입력")

    XCTAssertTrue(submitButton.isEnabled)
}
```

---

## 5. 네비게이션 테스트 (TCA NavigationStack / Sheet)

```swift
// NavigationStack 화면 전환
func test_pushesToDetail_whenRowTapped() {
    app.launch()
    app.cells["row_item_1"].tap()
    XCTAssert(app.navigationBars["상세 화면"].waitForExistence(timeout: 3))
}

// Sheet / FullScreenCover
func test_dismissesSheet_whenCloseButtonTapped() {
    app.launch()
    app.buttons[HomeAccessibilityID.openSheetButton].tap()
    XCTAssert(app.sheets.firstMatch.waitForExistence(timeout: 3))

    app.buttons[SheetAccessibilityID.closeButton].tap()
    XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 2))
}

// Alert
func test_showsAlert_whenDeleteConfirmed() {
    app.launch()
    app.buttons[FeatureAccessibilityID.deleteButton].tap()
    XCTAssert(app.alerts["삭제 확인"].waitForExistence(timeout: 3))
    app.alerts["삭제 확인"].buttons["삭제"].tap()
    XCTAssert(app.staticTexts[FeatureAccessibilityID.emptyState]
        .waitForExistence(timeout: 3))
}
```

---

## 6. 공통 UITest 규칙

### DO (해야 할 것)

- 테스트 메서드명은 `test_<expected>_when<Condition>` 형식으로 작성한다
- `continueAfterFailure = false`를 `setUpWithError`에서 항상 설정한다
- 각 테스트는 독립 실행 가능해야 하며, `setUpWithError`에서 앱을 새로 launch한다
- Accessibility Identifier는 Feature별 enum/struct 상수로 관리한다
- 비동기 요소는 항상 `waitForExistence(timeout:)`으로 대기한다
- 스크롤이 필요한 요소는 `swipeUp()` / `swipeDown()` 후 탐색한다

### DON'T (하지 말아야 할 것)

- `sleep()` 사용 금지 — `waitForExistence(timeout:)` 또는 `expectation`을 사용한다
- 하드코딩된 인덱스 접근 금지 (`element(boundBy: 0)`) — ID 기반 접근을 사용한다
- 실제 서버 API를 호출하는 테스트를 작성하지 않는다
- `XCTAssertTrue(element.exists)` 단독 사용 금지 — 비동기 요소에는 `waitForExistence` 필수
- 여러 화면을 하나의 테스트에서 연쇄 검증하지 않는다 (E2E와 UITest 구분)

### 네이밍 규칙

```
테스트 클래스:  <FeatureName>UITests.swift        (e.g., HomeUITests.swift)
AccessibilityID enum: <FeatureName>AccessibilityID (e.g., HomeAccessibilityID)
Launch Argument 상수: UITestLaunchArguments.swift  (앱 타겟 공유)
```

---

## 7. 자주 발생하는 실수 & 수정 방법

| 실수 | 원인 | 수정 |
|---|---|---|
| `Element not found` | Identifier 오타 또는 미적용 | View에 `.accessibilityIdentifier(...)` 추가 확인 |
| `Element is not hittable` | 요소가 화면 밖 또는 다른 뷰에 가려짐 | `swipeUp()` 후 재시도, 또는 스크롤 컨테이너 확인 |
| `waitForExistence` 타임아웃 | Dependency가 응답하지 않거나 너무 느림 | Launch Argument로 Mock 응답 설정 확인 |
| `테스트 간 상태 오염` | 앱 재시작 없이 상태 공유 | `setUpWithError`에서 `app.launch()` 호출 확인 |
| `Alert / Sheet 탐색 실패` | 애니메이션 완료 전 탐색 | `waitForExistence(timeout: 3)` 추가 |
| `실제 네트워크 호출` | Launch Argument 미전달 | `app.launchArguments = ["UITestMode", ...]` 확인 |
