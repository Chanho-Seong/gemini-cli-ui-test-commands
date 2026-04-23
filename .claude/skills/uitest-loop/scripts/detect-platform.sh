#!/usr/bin/env bash
#
# detect-platform.sh — 프로젝트 루트에서 Android / iOS 플랫폼과 메인 모듈 경로를 감지한다.
#
# 출력: KEY=VALUE 형식 (eval 가능)
#   PLATFORM=android|ios|unknown
#   MAIN_MODULE=<상대경로>            # android: 앱 모듈 (app, yogiyo, ...), ios: "."
#   PROJECT_ROOT=<절대경로>
#
# 사용법:
#   eval "$(bash detect-platform.sh)"
#   bash detect-platform.sh --cwd /path/to/project
#

set -euo pipefail

CWD="$(pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd) CWD="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,14p' "$0"
      exit 0
      ;;
    *) echo "# unknown option: $1" >&2; exit 2 ;;
  esac
done

cd "$CWD"
PROJECT_ROOT="$(pwd)"

detect_android_main_module() {
  local settings_file=""
  for f in settings.gradle settings.gradle.kts; do
    if [[ -f "$f" ]]; then settings_file="$f"; break; fi
  done

  if [[ -z "$settings_file" ]]; then
    # settings 가 없는 단일 모듈 — build.gradle* 있으면 루트 사용
    if [[ -f build.gradle || -f build.gradle.kts ]]; then
      echo "."
      return 0
    fi
    return 1
  fi

  # settings.gradle(.kts) 의 include(':xxx') 목록 추출
  local modules
  modules=$(grep -E "include[[:space:]]*\(?[[:space:]]*['\"]:" "$settings_file" \
    | sed -E "s/.*include[[:space:]]*\(?[[:space:]]*['\"]:([^'\"]+)['\"].*/\1/" \
    | tr ':' '/' \
    | awk 'NF' )

  # com.android.application 플러그인을 가진 첫 모듈을 메인 모듈로 간주
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    local gradle_file=""
    for g in "${m}/build.gradle" "${m}/build.gradle.kts"; do
      if [[ -f "$g" ]]; then gradle_file="$g"; break; fi
    done
    [[ -z "$gradle_file" ]] && continue
    if grep -qE "com\.android\.application|id[[:space:]]*\(?[[:space:]]*['\"]com\.android\.application['\"]" "$gradle_file"; then
      echo "$m"
      return 0
    fi
  done <<<"$modules"

  # fallback: 첫 번째 include 모듈
  local first
  first=$(echo "$modules" | head -1)
  if [[ -n "$first" ]]; then
    echo "$first"
    return 0
  fi

  # 최후: 루트
  echo "."
}

PLATFORM="unknown"
MAIN_MODULE="."

has_any() {
  for f in "$@"; do
    if [[ -e "$f" ]] || compgen -G "$f" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

if has_any build.gradle build.gradle.kts settings.gradle settings.gradle.kts; then
  PLATFORM="android"
  if mod=$(detect_android_main_module); then
    MAIN_MODULE="$mod"
  fi
elif has_any '*.xcworkspace' '*.xcodeproj'; then
  PLATFORM="ios"
  MAIN_MODULE="."
fi

printf 'PLATFORM=%s\n' "$PLATFORM"
printf 'MAIN_MODULE=%s\n' "$MAIN_MODULE"
printf 'PROJECT_ROOT=%s\n' "$PROJECT_ROOT"
