# JSON 출력 포맷팅 규칙 (uitest_results.json, device_verification.json)

`*_uitest_results.json`, `*_device_verification.json` 등 에이전트가 생성하는 JSON 파일은 **반드시 유효한 JSON**이어야 합니다. 줄바꿈, 쌍따옴표, 백슬래시 등 특수 문자로 인한 파싱 오류를 방지하기 위해 아래 규칙을 준수하세요.

## 1. 문자열 값 이스케이프 규칙

JSON 문자열 값 내부에 다음 문자를 **그대로 넣지 말고** 반드시 이스케이프하세요:

| 문자 | 이스케이프 | 설명 |
|------|------------|------|
| 줄바꿈 (LF) | `\n` | 실제 줄바꿈 대신 백슬래시+n |
| 캐리지리턴 (CR) | `\r` | |
| 탭 | `\t` | |
| 쌍따옴표 `"` | `\"` | 문자열 경계와 혼동 방지 |
| 백슬래시 `\` | `\\` | |
| 제어문자 (0x00-0x1F) | 해당 이스케이프 또는 공백으로 치환 | |

## 2. 금지 사항

- **절대 금지**: JSON 문자열 값 안에 실제 줄바꿈(개행)을 넣지 말 것. → `\n`으로 이스케이프.
- **절대 금지**: 문자열 안의 `"`를 이스케이프 없이 사용하지 말 것. → `\"`로 이스케이프.
- **절대 금지**: 수동으로 JSON 문자열을 조합하지 말 것. 가능하면 `json.dumps()` 또는 동등한 직렬화 사용.

## 3. 권장: 긴 텍스트 처리

`errorMessage`, `stackTrace`, `verificationNote` 등 여러 줄이 될 수 있는 필드:

- **옵션 A**: 줄바꿈을 `\n`으로 이스케이프하여 한 줄 JSON 문자열로 저장.
- **옵션 B**: 줄바꿈을 공백 ` ` 또는 ` | `로 치환하여 단일 줄로 저장 (가독성 희생, 파싱 안정성 확보).

## 4. 에이전트 작성 시 체크리스트

JSON 파일을 `run_shell_command`의 `echo` 등으로 작성할 때:

1. 모든 문자열 값에서 `"` → `\"`, `\` → `\\`, 실제 줄바꿈 → `\n` 적용 여부 확인.
2. `echo` 사용 시 셸 이스케이프와 JSON 이스케이프가 중첩되지 않도록 주의.
3. **가능하면** `python3 -c "import json; ..."` 또는 `bin/parse-android-test-results.py` 같은 스크립트로 JSON 생성.

## 5. 적용 대상

- **run-test-android.sh** + **parse-am-instrument-results.py**: `*_uitest_results.json` 작성 시
- **verifier-agent**: `*_device_verification.json` 작성 시
- **parse-android-test-results.py**: `json.dumps()` 사용으로 자동 이스케이프됨 (추가 조치 불필요)

## 6. 안전한 JSON 작성 도구

- **parse-android-test-results.py**: uitest_results.json 생성 시 사용 (JUnit XML → JSON).
- **bin/write-json.py**: 임의 JSON을 stdin으로 받아 파일에 기록. 이스케이프는 입력 JSON이 유효해야 함. 에이전트가 복잡한 내용(줄바꿈 포함)을 쓸 때 `python3 -c "import json; print(json.dumps(obj))" | python3 bin/write-json.py <path>` 형태로 사용 권장.
