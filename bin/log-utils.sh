#!/usr/bin/env bash
#
# log-utils.sh -- UITest pipeline shared logging utility
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/log-utils.sh"
#   _LOG_SOURCE="my-script"
#   _LOG_FILE="/path/to/logfile.log"   # optional: also write to file
#   log_info "Something happened"
#   log_error "Something went wrong"
#
# Environment variables:
#   LOG_LEVEL       -- minimum log level to output (DEBUG|INFO|WARN|ERROR, default: INFO)
#   LOG_KEEP_RUNS   -- number of run directories to keep (default: 10)
#

# Guard against multiple sourcing
[[ -n "${_LOG_UTILS_LOADED:-}" ]] && return 0
_LOG_UTILS_LOADED=1

# ─── Log level constants ────────────────────────────────────────────────────
_LOG_LEVEL_DEBUG=0
_LOG_LEVEL_INFO=1
_LOG_LEVEL_WARN=2
_LOG_LEVEL_ERROR=3

# Current threshold (default: INFO)
_LOG_THRESHOLD="$_LOG_LEVEL_INFO"
case "${LOG_LEVEL:-INFO}" in
  DEBUG|debug) _LOG_THRESHOLD=$_LOG_LEVEL_DEBUG ;;
  INFO|info)   _LOG_THRESHOLD=$_LOG_LEVEL_INFO ;;
  WARN|warn)   _LOG_THRESHOLD=$_LOG_LEVEL_WARN ;;
  ERROR|error) _LOG_THRESHOLD=$_LOG_LEVEL_ERROR ;;
esac

# ─── Core log function ──────────────────────────────────────────────────────
#
# _log <LEVEL> <SOURCE> <message...>
#   Output format: [2026-03-29T14:05:22Z] [INFO] [pipeline] message
#   - INFO/DEBUG  -> stdout
#   - WARN/ERROR  -> stderr
#   - If _LOG_FILE is set, also appends to that file
#
_log() {
  local level="$1" source="$2"; shift 2
  local level_num
  case "$level" in
    DEBUG) level_num=$_LOG_LEVEL_DEBUG ;;
    INFO)  level_num=$_LOG_LEVEL_INFO ;;
    WARN)  level_num=$_LOG_LEVEL_WARN ;;
    ERROR) level_num=$_LOG_LEVEL_ERROR ;;
    *)     level_num=$_LOG_LEVEL_INFO ;;
  esac

  [[ $level_num -ge $_LOG_THRESHOLD ]] || return 0

  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local line="[$ts] [$level] [$source] $*"

  if [[ "$level" == "ERROR" || "$level" == "WARN" ]]; then
    echo "$line" >&2
  else
    echo "$line"
  fi

  if [[ -n "${_LOG_FILE:-}" ]]; then
    echo "$line" >> "$_LOG_FILE"
  fi
}

# ─── Convenience wrappers ───────────────────────────────────────────────────
# Each script sets _LOG_SOURCE after sourcing this file.
log_debug() { _log DEBUG "${_LOG_SOURCE:-unknown}" "$@"; }
log_info()  { _log INFO  "${_LOG_SOURCE:-unknown}" "$@"; }
log_warn()  { _log WARN  "${_LOG_SOURCE:-unknown}" "$@"; }
log_error() { _log ERROR "${_LOG_SOURCE:-unknown}" "$@"; }

# ─── Run directory helpers ──────────────────────────────────────────────────

# create_run_dir <logs_dir>
#   Creates a timestamped run directory and a "latest" symlink.
#   Sets RUN_ID and RUN_DIR variables, then exports them.
create_run_dir() {
  local logs_dir="$1"
  RUN_ID="run_$(date -u +%Y%m%dT%H%M%SZ)"
  RUN_DIR="$logs_dir/$RUN_ID"
  mkdir -p "$RUN_DIR"
  ln -sfn "$RUN_ID" "$logs_dir/latest"
  export RUN_ID RUN_DIR
}

# cleanup_old_runs <logs_dir> [keep_count]
#   Removes run_* directories older than the N most recent.
#   Also removes broken symlinks in the logs directory.
cleanup_old_runs() {
  local logs_dir="$1"
  local keep="${2:-${LOG_KEEP_RUNS:-10}}"

  # Collect run directories sorted newest-first (name is timestamp-based)
  local run_dirs=()
  while IFS= read -r d; do
    run_dirs+=("$d")
  done < <(ls -d "$logs_dir"/run_* 2>/dev/null | sort -r)

  local total=${#run_dirs[@]}
  if [[ $total -le $keep ]]; then
    return 0
  fi

  local i
  for (( i=keep; i<total; i++ )); do
    _log INFO "cleanup" "Removing old run: $(basename "${run_dirs[$i]}")"
    rm -rf "${run_dirs[$i]}"
  done

  # Clean up broken symlinks
  find "$logs_dir" -maxdepth 1 -type l ! -exec test -e {} \; -delete 2>/dev/null || true
}
