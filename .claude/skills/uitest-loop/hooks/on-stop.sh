#!/usr/bin/env bash
#
# on-stop.sh — Claude Stop 훅. UI Test Loop skill 종료 시 최종 알림 발행.
#
# Claude Code 가 이 훅을 호출할 때 JSON payload 를 stdin 으로 전달할 수도 있지만
# 여기서는 별도 입력 없이 상태를 재조회해 알림만 발행한다.
#

set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 현재 프로젝트의 build/ai-uitest 경로 추론
BUILD_DIR=""
if BUILD_DIR="$(bash "$SKILL_ROOT/scripts/resolve-build-dir.sh" 2>/dev/null)"; then
  :
fi

STATUS="aborted"
DETAIL="종료됨"

if [[ -n "$BUILD_DIR" && -f "$BUILD_DIR/summary.md" ]]; then
  STATUS="complete"
  DETAIL="리포트: $BUILD_DIR/summary.md"
fi

bash "$SKILL_ROOT/scripts/notify-step.sh" "$STATUS" "$DETAIL" >/dev/null 2>&1 || true

exit 0
