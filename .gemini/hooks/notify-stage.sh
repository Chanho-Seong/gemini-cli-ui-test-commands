#!/bin/bash
#
# notify-stage.sh — AfterTool hook
#
# run_shell_command 실행 결과에서 파이프라인 단계 전환 키워드를 감지하여
# macOS 데스크톱 알림을 전송합니다.
#
# stdin: AfterTool 이벤트 JSON (toolName, result 등)
# stdout: JSON (반드시 유효한 JSON만 출력)
# stderr: 디버그 로그용
#

read -r INPUT_JSON

# toolName 추출
TOOL_NAME=$(echo "$INPUT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('toolName',''))" 2>/dev/null)

# run_shell_command가 아니면 즉시 통과
if [[ "$TOOL_NAME" != "run_shell_command" ]]; then
  echo '{}' >&1
  exit 0
fi

# 결과 텍스트 추출
RESULT_TEXT=$(echo "$INPUT_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
result = data.get('result', data.get('output', ''))
if isinstance(result, dict):
    result = json.dumps(result)
print(str(result)[:2000])
" 2>/dev/null || echo "")

# 단계 감지 키워드 매칭
TITLE=""
MESSAGE=""

if echo "$RESULT_TEXT" | grep -qi "run-test-android.sh\|run-test-ios.sh\|xcodebuild.*test\|am instrument"; then
  if echo "$RESULT_TEXT" | grep -qi "exit\|complete\|finish\|done\|결과"; then
    TITLE="테스트 실행 완료"
    MESSAGE="UITest 실행이 완료되었습니다. 결과를 확인하세요."
  fi
elif echo "$RESULT_TEXT" | grep -qi "verify.*shard\|verifier-agent.*done\|verification.*complete\|merge-verification"; then
  TITLE="디바이스 검증 완료"
  MESSAGE="Verifier-agent 검증이 완료되었습니다."
elif echo "$RESULT_TEXT" | grep -qi "coder-agent.*done\|fix_report.*json\|fix.*complete"; then
  TITLE="코드 수정 완료"
  MESSAGE="Coder-agent 수정 작업이 완료되었습니다."
elif echo "$RESULT_TEXT" | grep -qi "pr-agent.*done\|pr.*create\|pull request\|pr_report"; then
  TITLE="PR 생성 완료"
  MESSAGE="Pull Request가 생성되었습니다."
fi

# 알림 전송
if [[ -n "$TITLE" ]]; then
  osascript -e "display notification \"$MESSAGE\" with title \"Gemini Pipeline\" subtitle \"$TITLE\" sound name \"Glass\"" 2>/dev/null &
  echo "[$TITLE] $MESSAGE" >&2
fi

echo '{}' >&1
exit 0
