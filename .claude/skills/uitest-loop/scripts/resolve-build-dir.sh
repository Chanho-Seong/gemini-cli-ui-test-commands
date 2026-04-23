#!/usr/bin/env bash
#
# resolve-build-dir.sh — 멀티모듈 구조를 반영하여 <main_module>/build/ai-uitest 경로를 결정적으로 산출
#
# 출력: 산출된 빌드 디렉토리 절대 경로 (stdout 1줄)
#
# 사용법:
#   BUILD_DIR="$(bash resolve-build-dir.sh)"
#   BUILD_DIR="$(bash resolve-build-dir.sh --module app)"
#
# 우선순위:
#   1. --module <name>   # 명시적 인자
#   2. detect-platform.sh 자동 감지
#   3. 루트 ./build/ai-uitest (fallback)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODULE_OVERRIDE=""
CWD="$(pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --module) MODULE_OVERRIDE="$2"; shift 2 ;;
    --cwd) CWD="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,15p' "$0"
      exit 0
      ;;
    *) echo "# unknown option: $1" >&2; exit 2 ;;
  esac
done

cd "$CWD"

MAIN_MODULE="."
PLATFORM="unknown"

if [[ -n "$MODULE_OVERRIDE" ]]; then
  MAIN_MODULE="${MODULE_OVERRIDE//://}"  # gradle `:feature:login` → `feature/login`
  MAIN_MODULE="${MAIN_MODULE#/}"
else
  # detect-platform.sh 결과 재사용
  eval "$(bash "$SCRIPT_DIR/detect-platform.sh")"
fi

# iOS 는 루트 기준
if [[ "${PLATFORM}" == "ios" ]]; then
  MAIN_MODULE="."
fi

if [[ "$MAIN_MODULE" == "." || -z "$MAIN_MODULE" ]]; then
  BUILD_DIR="$(pwd)/build/ai-uitest"
else
  BUILD_DIR="$(pwd)/${MAIN_MODULE}/build/ai-uitest"
fi

echo "$BUILD_DIR"
