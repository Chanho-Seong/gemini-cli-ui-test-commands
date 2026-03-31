# Android UITest Conventions (MVI + Clean Architecture + Hilt)

## 1. Architecture Overview (UITest 관점)

### 레이어 구조 요약

```
presentation/
  ui/
    <FeatureName>/
      <FeatureName>Screen.kt         ← Composable or Fragment (UI)
      <FeatureName>ViewModel.kt      ← ViewModel (State 보유, Intent 처리)
      <FeatureName>Contract.kt       ← UiState, UiIntent, UiEffect 정의
domain/
  usecase/
    <ActionName>UseCase.kt
  repository/
    <Name>Repository.kt              ← interface
data/
  repository/
    <Name>RepositoryImpl.kt          ← Hilt로 바인딩
  di/
    <Feature>Module.kt               ← @Module, @Provides / @Binds
```

### MVI 핵심 개념 (테스트 필수 이해)

- **UiState**: ViewModel이 보유하는 화면 상태 (data class). `StateFlow<UiState>`로 노출
- **UiIntent**: 사용자 액션 (sealed class). ViewModel의 `handleIntent(intent)` 혹은 `onIntent(intent)`로 전달
- **UiEffect**: 일회성 사이드 이펙트 (navigation, toast 등). `SharedFlow<UiEffect>`로 노출

UITest에서 **UiState 변화**가 화면에 반영되는 것을 검증하는 것이 핵심이다.

---

## 2. Hilt UITest 기본 설정

### 필수 어노테이션

```kotlin
@HiltAndroidTest
class FeatureScreenTest {
    @get:Rule(order = 0)
    val hiltRule = HiltAndroidRule(this)

    @get:Rule(order = 1)
    val composeRule = createAndroidComposeRule<HiltTestActivity>()
    // 또는 ActivityScenarioRule<MainActivity>()

    @Before
    fun setUp() {
        hiltRule.inject()
    }
}
```

### 의존성 교체 방법

```kotlin
// 모듈 전체 교체
@UninstallModules(NetworkModule::class)
@HiltAndroidTest
class FeatureScreenTest {

    // 개별 바인딩 교체
    @BindValue
    val fakeRepository: FeatureRepository = FakeFeatureRepository()
}
```

**규칙:**
- 실제 네트워크/DB를 호출하는 테스트는 작성하지 않는다 — 항상 Fake 또는 Mock으로 교체
- `@UninstallModules`로 프로덕션 모듈을 제거하고 `@BindValue`로 테스트용 구현체를 주입한다
- Fake 구현체는 테스트 소스셋(`androidTest/`) 안에 위치시킨다

---

## 3. Compose UITest 규칙

### 기본 구조

```kotlin
@Test
fun `should display title when screen loads`() {
    // Given: 초기 상태 설정 (Fake Repository 등)
    fakeRepository.setResponse(successData)

    // When: 화면 진입
    composeRule.setContent {
        FeatureScreen(viewModel = hiltViewModel())
    }

    // Then: UI 검증
    composeRule.onNodeWithTag("feature_title").assertIsDisplayed()
    composeRule.onNodeWithText("Expected Title").assertExists()
}
```

### 자주 사용하는 Finder

| 상황 | 사용 방법 |
|---|---|
| 테스트 전용 식별자로 찾기 | `onNodeWithTag("tag_name")` ← **권장** |
| 화면에 보이는 텍스트로 찾기 | `onNodeWithText("텍스트")` |
| ContentDescription으로 찾기 | `onNodeWithContentDescription("설명")` |
| 역할(Role)로 찾기 | `onNode(hasRole(Role.Button))` |
| 복합 조건 | `onNode(hasTestTag("x") and hasText("y"))` |

### TestTag 규칙

```kotlin
// 프로덕션 코드에서 TestTag 상수 정의
object FeatureTestTags {
    const val SCREEN_ROOT = "feature_screen_root"
    const val SUBMIT_BUTTON = "feature_submit_button"
    const val ERROR_MESSAGE = "feature_error_message"
    const val LOADING_INDICATOR = "feature_loading_indicator"
}

// Composable에서 적용
Box(modifier = Modifier.testTag(FeatureTestTags.SCREEN_ROOT))
```

**규칙:**
- Resource ID 대신 `testTag`를 사용한다 — Compose에는 R.id가 없다
- TestTag는 `object`로 상수 관리하고, 테스트와 프로덕션 코드가 같은 상수를 공유한다
- TestTag 네이밍: `<feature>_<component>` (소문자 스네이크케이스)

### 비동기 대기

```kotlin
// Compose는 자동으로 recomposition을 대기하지만, 외부 비동기가 끼면 명시적 대기 필요
composeRule.waitUntil(timeoutMillis = 3000) {
    composeRule.onAllNodesWithTag("item_card").fetchSemanticsNodes().isNotEmpty()
}

// 단순 대기
composeRule.waitForIdle()
```

---

## 4. XML + Espresso UITest 규칙 (Legacy 화면 대응)

### 기본 패턴

```kotlin
// View 찾기
onView(withId(R.id.btn_submit))
onView(withText("확인"))
onView(allOf(withId(R.id.tv_name), isDisplayed()))

// 액션
onView(withId(R.id.et_input)).perform(typeText("입력값"), closeSoftKeyboard())
onView(withId(R.id.btn_submit)).perform(click())
onView(withId(R.id.rv_list)).perform(scrollToPosition<RecyclerView.ViewHolder>(5))

// 검증
onView(withId(R.id.tv_result)).check(matches(withText("결과")))
onView(withId(R.id.progress_bar)).check(matches(not(isDisplayed())))
```

### RecyclerView 아이템 검증

```kotlin
onView(withId(R.id.rv_list))
    .perform(scrollToPosition<RecyclerView.ViewHolder>(0))

onView(withRecyclerView(R.id.rv_list).atPosition(0))
    .check(matches(hasDescendant(withText("첫번째 아이템"))))
```

---

## 5. MVI 상태 기반 테스트 전략

### 상태별 시나리오 구성 원칙

각 UiState 케이스마다 테스트를 작성한다:

```kotlin
// Loading 상태
@Test
fun `should show loading indicator when state is Loading`() {
    fakeRepository.setLoading()
    launchScreen()
    onNodeWithTag(TestTags.LOADING_INDICATOR).assertIsDisplayed()
}

// Success 상태
@Test
fun `should show content when state is Success`() {
    fakeRepository.setSuccess(mockData)
    launchScreen()
    onNodeWithTag(TestTags.CONTENT).assertIsDisplayed()
}

// Error 상태
@Test
fun `should show error message when state is Error`() {
    fakeRepository.setError(IOException("Network error"))
    launchScreen()
    onNodeWithTag(TestTags.ERROR_MESSAGE).assertIsDisplayed()
}
```

### Intent → 상태 전환 검증

```kotlin
@Test
fun `should navigate to detail when item clicked`() {
    fakeRepository.setSuccess(listOf(mockItem))
    launchScreen()

    composeRule.onNodeWithTag("item_${mockItem.id}").performClick()

    // Navigation Effect 검증 또는 다음 화면 진입 검증
    composeRule.onNodeWithTag("detail_screen_root").assertIsDisplayed()
}
```

---

## 6. 공통 UITest 규칙

### DO (해야 할 것)

- 테스트 메서드명은 `should_<expected>_when_<condition>` 또는 `` `should ... when ...` `` (백틱 한국어 허용) 형식으로 작성한다
- 각 테스트는 독립적으로 실행 가능해야 한다 (`@Before`로 상태 초기화)
- 하나의 테스트는 하나의 동작만 검증한다
- 실패 원인 파악을 위해 `assertIsDisplayed()` 전에 `assertExists()`로 존재 여부를 먼저 확인한다
- 타이밍 의존성이 있는 검증은 `waitUntil` 또는 `IdlingResource`를 사용한다

### DON'T (하지 말아야 할 것)

- `Thread.sleep()` 사용 금지 — `waitUntil` 또는 `IdlingResource`를 사용한다
- 절대 경로 또는 하드코딩된 디바이스 정보를 사용하지 않는다
- 프로덕션 네트워크/DB를 직접 호출하지 않는다
- 한 테스트에서 여러 화면을 연쇄 검증하지 않는다 (E2E 테스트와 구분)
- `onView(...).check(doesNotExist())`로 부재 검증 시, 존재하지 않는 View ID 사용을 주의한다

### 네이밍 규칙

```
테스트 클래스:  <FeatureName>ScreenTest.kt   (e.g., HomeScreenTest.kt)
Fake 클래스:   Fake<InterfaceName>.kt        (e.g., FakeUserRepository.kt)
TestTag 상수:  <FeatureName>TestTags.kt      (e.g., HomeTestTags.kt)
```

---

## 7. 자주 발생하는 실수 & 수정 방법

| 실수 | 원인 | 수정 |
|---|---|---|
| `TestTag를 찾을 수 없음` | Composable에 `.testTag()` 미적용 | 프로덕션 Composable에 `Modifier.testTag(tag)` 추가 |
| `hiltRule.inject() 미호출` | `@Before`에서 inject 빠짐 | `setUp()`에 `hiltRule.inject()` 추가 |
| `Fake가 주입되지 않음` | `@UninstallModules` 누락 | 클래스에 `@UninstallModules(XxxModule::class)` 추가 |
| `비동기 상태 미반영` | 상태 변화 대기 없음 | `composeRule.waitForIdle()` 또는 `waitUntil` 추가 |
| `다른 테스트에 상태 오염` | `@Before` 초기화 부족 | `@Before`에서 Fake 상태 리셋 |
