#!/bin/bash
#
# notify-pipeline-done.sh — AfterAgent hook
#
# 에이전트 루프(파이프라인 포함)가 종료될 때 최종 알림을 전송합니다.
#
# stdin: AfterAgent 이벤트 JSON
# stdout: JSON
# stderr: 디버그 로그용
#

read -r INPUT_JSON

# 에이전트 응답에서 파이프라인 관련 키워드 감지
IS_PIPELINE=$(echo "$INPUT_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
response = str(data.get('response', data.get('output', '')))[:3000]
keywords = ['파이프라인 완료', 'Pipeline Complete', '파이프라인을 종료', '최종 요약']
found = any(k in response for k in keywords)
print('yes' if found else 'no')
" 2>/dev/null || echo "no")

if [[ "$IS_PIPELINE" == "yes" ]]; then
  osascript -e 'display notification "모든 단계가 완료되었습니다. 결과를 확인하세요." with title "Gemini Pipeline" subtitle "파이프라인 완료" sound name "Hero"' 2>/dev/null &
  echo "[파이프라인 완료] 최종 알림 전송" >&2
fi

echo '{}' >&1
exit 0
