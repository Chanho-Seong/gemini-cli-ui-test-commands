#!/usr/bin/env bash
#
# notify-step.sh — UI Test Loop 단계 알림을 데스크탑 알림으로 발행
#
# 사용법:
#   bash notify-step.sh <step-id> [message]
#
# step-id:
#   start | tests-done | verify-done | fix-done | retest-done | complete | aborted | post-bash
#
# 비활성화:
#   AI_UITEST_NOTIFY=off  (환경변수)
#   --no-notify          (인자)
#
# 실패해도 exit 0 (알림 실패로 파이프라인 중단 금지)
#

NOTIFY_ENABLED=true
if [[ "${AI_UITEST_NOTIFY:-}" == "off" ]]; then
  NOTIFY_ENABLED=false
fi

STEP="${1:-info}"
shift || true

# --no-notify 플래그 소비
ARGS=()
for a in "$@"; do
  if [[ "$a" == "--no-notify" ]]; then
    NOTIFY_ENABLED=false
  else
    ARGS+=("$a")
  fi
done

MSG="${ARGS[*]:-}"
if [[ -z "$MSG" ]]; then
  MSG="$STEP"
fi

TITLE="UI Test Loop"

# post-bash 는 throttle (30초)
if [[ "$STEP" == "post-bash" ]]; then
  # 상태 파일 위치: 프로젝트 빌드 디렉토리 하위. 없으면 /tmp fallback.
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  THROTTLE_DIR="${AI_UITEST_THROTTLE_DIR:-/tmp}"
  THROTTLE_FILE="$THROTTLE_DIR/.ai-uitest-throttle"
  NOW=$(date +%s)
  if [[ -f "$THROTTLE_FILE" ]]; then
    LAST=$(cat "$THROTTLE_FILE" 2>/dev/null || echo 0)
    if (( NOW - LAST < 30 )); then
      exit 0  # throttled
    fi
  fi
  echo "$NOW" > "$THROTTLE_FILE" 2>/dev/null || true
  # post-bash 는 단순 기본 메시지로 대체
  MSG="Bash 커맨드 완료"
fi

if [[ "$NOTIFY_ENABLED" == "false" ]]; then
  exit 0
fi

# Platform-specific notification
UNAME="$(uname -s 2>/dev/null || echo Unknown)"
case "$UNAME" in
  Darwin)
    # macOS: osascript. subtitle 에 step id, body 에 message
    /usr/bin/osascript -e "display notification \"${MSG//\"/\\\"}\" with title \"${TITLE}\" subtitle \"${STEP}\" sound name \"Glass\"" >/dev/null 2>&1 || true
    ;;
  Linux)
    if command -v notify-send >/dev/null 2>&1; then
      notify-send -a "$TITLE" "$STEP" "$MSG" >/dev/null 2>&1 || true
    fi
    ;;
  MINGW*|CYGWIN*|MSYS*)
    # Windows: PowerShell BurntToast → fallback 없이 silent
    powershell.exe -NoProfile -Command \
      "try { Import-Module BurntToast -ErrorAction Stop; New-BurntToastNotification -Text '${TITLE}', '${STEP}: ${MSG}' } catch {}" \
      >/dev/null 2>&1 || true
    ;;
esac

exit 0
