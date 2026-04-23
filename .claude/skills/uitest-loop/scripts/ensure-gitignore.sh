#!/usr/bin/env bash
#
# ensure-gitignore.sh — <build-dir> 가 git 에 추적되지 않도록 .gitignore 항목 확인/추가
#
# 사용법:
#   bash ensure-gitignore.sh <build-dir>
#
# 동작:
#   1. build-dir 이 루트 .gitignore 의 기존 패턴("build/", "**/build/" 등)으로 이미 커버되는지 확인
#   2. 커버되지 않으면 프로젝트 루트 .gitignore 에 상대 경로 추가
#   3. 프로젝트가 git 저장소가 아니면 no-op
#

set -u

BUILD_DIR="${1:-}"
if [[ -z "$BUILD_DIR" ]]; then
  echo "usage: ensure-gitignore.sh <build-dir>" >&2
  exit 2
fi

# git repo root 찾기 (physical path 로 정규화)
if ! GIT_ROOT_RAW="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "[ensure-gitignore] not a git repo, skipping"
  exit 0
fi
GIT_ROOT="$(cd "$GIT_ROOT_RAW" && pwd -P)"

# BUILD_DIR 을 physical 절대 경로로
mkdir -p "$BUILD_DIR"
BUILD_DIR_ABS="$(cd "$BUILD_DIR" && pwd -P)"

REL_PATH="${BUILD_DIR_ABS#"$GIT_ROOT/"}"
if [[ "$REL_PATH" == "$BUILD_DIR_ABS" ]]; then
  # prefix 미매칭 → Python realpath fallback
  REL_PATH="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$BUILD_DIR_ABS" "$GIT_ROOT")"
fi

# 이미 ignored 되었는지 git 에게 물어봄 (디렉토리 미존재 시 가상 파일로)
if git -C "$GIT_ROOT" check-ignore "$BUILD_DIR_ABS/.probe" >/dev/null 2>&1; then
  echo "[ensure-gitignore] already covered by existing .gitignore patterns"
  exit 0
fi

GITIGNORE="$GIT_ROOT/.gitignore"
ENTRY="$REL_PATH/"

# 이미 같은 라인이 있으면 skip
if [[ -f "$GITIGNORE" ]] && grep -Fxq "$ENTRY" "$GITIGNORE"; then
  echo "[ensure-gitignore] entry already present: $ENTRY"
  exit 0
fi

{
  [[ -f "$GITIGNORE" && -s "$GITIGNORE" ]] && echo ""
  echo "# UI Test Loop skill artifacts"
  echo "$ENTRY"
} >> "$GITIGNORE"
echo "[ensure-gitignore] added: $ENTRY"
