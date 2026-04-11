#!/usr/bin/env bash
#
# device-pool.sh — 디바이스 풀 매니저
# OS별 가용 디바이스 수만큼 병렬 실행을 제한하고, 태스크 간 디바이스 충돌을 방지합니다.
#
# 사용법:
#   device-pool.sh discover                    # OS별 연결 디바이스 스캔 → device_pool.json 갱신
#   device-pool.sh acquire <os> <task_id>      # 유휴 디바이스 1대 잠금, device_id 반환
#   device-pool.sh release <device_id>         # 잠금 해제
#   device-pool.sh status                      # 전체 디바이스 상태 출력
#   device-pool.sh cleanup                     # 고아 잠금 정리 (PID 체크)
#   device-pool.sh count <os>                  # 해당 OS의 가용(idle) 디바이스 수 반환
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="$PROJECT_ROOT/.gemini/agents/state"
LOCKS_DIR="$STATE_DIR/locks"
POOL_FILE="$STATE_DIR/device_pool.json"
LOCK_TTL_SECONDS=1800  # 30분

mkdir -p "$STATE_DIR" "$LOCKS_DIR"

usage() {
  cat <<'EOF'
Usage: device-pool.sh <command> [args]

Commands:
  discover                    Scan connected devices (Android via adb, iOS via xcrun simctl)
  acquire <os> <task_id>      Lock an idle device for a task. Prints device_id on success.
                              os: android | ios
                              Exit code 1 if no idle device available.
  release <device_id>         Release a locked device.
  status                      Print device pool status table.
  cleanup                     Remove stale locks (dead PIDs or TTL expired).
  count <os>                  Print number of idle devices for given OS.
EOF
  exit 1
}

timestamp_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

epoch_now() {
  date +%s
}

# Parse ISO timestamp to epoch (macOS compatible)
iso_to_epoch() {
  local ts="$1"
  if [[ "$(uname)" == "Darwin" ]]; then
    date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || echo 0
  else
    date -d "$ts" +%s 2>/dev/null || echo 0
  fi
}

# ─── discover ───────────────────────────────────────────────────────────────

discover_android() {
  local devices=()
  if ! command -v adb &>/dev/null; then
    echo "[]"
    return
  fi

  while IFS= read -r line; do
    # Skip header and empty lines
    [[ "$line" == "List of devices attached" ]] && continue
    [[ -z "$line" ]] && continue

    local id model status_raw
    id="$(echo "$line" | awk '{print $1}')"
    status_raw="$(echo "$line" | awk '{print $2}')"

    [[ "$status_raw" == "device" ]] || continue

    # Extract model from device properties
    model="$(echo "$line" | grep -o 'model:[^ ]*' | cut -d: -f2 || echo "unknown")"
    [[ -z "$model" ]] && model="unknown"

    # Check if locked
    local lock_status="idle" locked_by="" locked_at=""
    if [[ -d "$LOCKS_DIR/${id}.lock.d" ]] && [[ -f "$LOCKS_DIR/${id}.lock.d/info.json" ]]; then
      lock_status="locked"
      locked_by="$(python3 -c "import json; d=json.load(open('$LOCKS_DIR/${id}.lock.d/info.json')); print(d.get('taskId',''))" 2>/dev/null || echo "")"
      locked_at="$(python3 -c "import json; d=json.load(open('$LOCKS_DIR/${id}.lock.d/info.json')); print(d.get('lockedAt',''))" 2>/dev/null || echo "")"
    fi

    devices+=("{\"id\":\"$id\",\"model\":\"$model\",\"status\":\"$lock_status\",\"lockedBy\":$([ -n "$locked_by" ] && echo "\"$locked_by\"" || echo "null"),\"lockedAt\":$([ -n "$locked_at" ] && echo "\"$locked_at\"" || echo "null")}")
  done < <(adb devices -l 2>/dev/null)

  local joined
  joined="$(IFS=,; echo "${devices[*]}")"
  echo "[${joined}]"
}

discover_ios() {
  local devices=()
  if ! command -v xcrun &>/dev/null; then
    echo "[]"
    return
  fi

  # Get booted simulators
  while IFS= read -r line; do
    local id name
    # Parse lines like: "iPhone 15 (XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX) (Booted)"
    id="$(echo "$line" | grep -o '[0-9A-F]\{8\}-[0-9A-F]\{4\}-[0-9A-F]\{4\}-[0-9A-F]\{4\}-[0-9A-F]\{12\}' || true)"
    [[ -z "$id" ]] && continue
    name="$(echo "$line" | sed 's/ ([0-9A-F].*//' | xargs)"

    local lock_status="idle" locked_by="" locked_at=""
    if [[ -d "$LOCKS_DIR/${id}.lock.d" ]] && [[ -f "$LOCKS_DIR/${id}.lock.d/info.json" ]]; then
      lock_status="locked"
      locked_by="$(python3 -c "import json; d=json.load(open('$LOCKS_DIR/${id}.lock.d/info.json')); print(d.get('taskId',''))" 2>/dev/null || echo "")"
      locked_at="$(python3 -c "import json; d=json.load(open('$LOCKS_DIR/${id}.lock.d/info.json')); print(d.get('lockedAt',''))" 2>/dev/null || echo "")"
    fi

    devices+=("{\"id\":\"$id\",\"model\":\"$name\",\"status\":\"$lock_status\",\"lockedBy\":$([ -n "$locked_by" ] && echo "\"$locked_by\"" || echo "null"),\"lockedAt\":$([ -n "$locked_at" ] && echo "\"$locked_at\"" || echo "null")}")
  done < <(xcrun simctl list devices available 2>/dev/null | grep "(Booted)")

  # Also check for physical iOS devices via instruments or devicectl
  if command -v devicectl &>/dev/null; then
    while IFS= read -r line; do
      local id name
      id="$(echo "$line" | grep -o '[0-9a-f]\{8\}-[0-9a-f]*' | head -1 || true)"
      [[ -z "$id" ]] && continue
      name="$(echo "$line" | awk -F'  +' '{print $1}' | xargs)"

      local lock_status="idle" locked_by="" locked_at=""
      if [[ -d "$LOCKS_DIR/${id}.lock.d" ]] && [[ -f "$LOCKS_DIR/${id}.lock.d/info.json" ]]; then
        lock_status="locked"
        locked_by="$(python3 -c "import json; d=json.load(open('$LOCKS_DIR/${id}.lock.d/info.json')); print(d.get('taskId',''))" 2>/dev/null || echo "")"
        locked_at="$(python3 -c "import json; d=json.load(open('$LOCKS_DIR/${id}.lock.d/info.json')); print(d.get('lockedAt',''))" 2>/dev/null || echo "")"
      fi

      devices+=("{\"id\":\"$id\",\"model\":\"$name\",\"status\":\"$lock_status\",\"lockedBy\":$([ -n "$locked_by" ] && echo "\"$locked_by\"" || echo "null"),\"lockedAt\":$([ -n "$locked_at" ] && echo "\"$locked_at\"" || echo "null")}")
    done < <(xcrun devicectl list devices 2>/dev/null | tail -n +3 || true)
  fi

  local joined
  joined="$(IFS=,; echo "${devices[*]}")"
  echo "[${joined}]"
}

cmd_discover() {
  local android_json ios_json now
  android_json="$(discover_android)"
  ios_json="$(discover_ios)"
  now="$(timestamp_now)"

  python3 -c "
import json, sys
android = json.loads('''$android_json''')
ios = json.loads('''$ios_json''')
pool = {
    'lastUpdated': '$now',
    'devices': {
        'android': android,
        'ios': ios
    }
}
with open('$POOL_FILE', 'w') as f:
    json.dump(pool, f, indent=2, ensure_ascii=False)

android_count = len(android)
ios_count = len(ios)
android_idle = sum(1 for d in android if d['status'] == 'idle')
ios_idle = sum(1 for d in ios if d['status'] == 'idle')
print(f'Discovered: Android {android_count} ({android_idle} idle), iOS {ios_count} ({ios_idle} idle)')
print(f'Pool file: $POOL_FILE')
"
}

# ─── acquire ────────────────────────────────────────────────────────────────

cmd_acquire() {
  local os="$1"
  local task_id="$2"
  local caller_pid="${3:-$$}"

  [[ -z "$os" || -z "$task_id" ]] && { echo "Usage: device-pool.sh acquire <os> <task_id> [pid]" >&2; exit 1; }

  # Read pool file
  if [[ ! -f "$POOL_FILE" ]]; then
    echo "Error: device_pool.json not found. Run 'device-pool.sh discover' first." >&2
    exit 1
  fi

  # Find idle devices for the given OS
  local device_id
  device_id="$(python3 -c "
import json
pool = json.load(open('$POOL_FILE'))
devices = pool.get('devices', {}).get('$os', [])
for d in devices:
    if d['status'] == 'idle':
        print(d['id'])
        break
" 2>/dev/null)"

  if [[ -z "$device_id" ]]; then
    echo "No idle $os device available" >&2
    exit 1
  fi

  # Atomic lock via mkdir (mkdir is atomic on POSIX)
  local lock_dir="$LOCKS_DIR/${device_id}.lock.d"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "Device $device_id is already locked" >&2
    exit 1
  fi

  # Write lock info
  local now
  now="$(timestamp_now)"
  python3 -c "
import json
info = {
    'taskId': '$task_id',
    'agent': '',
    'lockedAt': '$now',
    'pid': $caller_pid,
    'os': '$os'
}
with open('$lock_dir/info.json', 'w') as f:
    json.dump(info, f, indent=2)
"

  # Update pool file
  python3 -c "
import json
pool = json.load(open('$POOL_FILE'))
for d in pool.get('devices', {}).get('$os', []):
    if d['id'] == '$device_id':
        d['status'] = 'locked'
        d['lockedBy'] = '$task_id'
        d['lockedAt'] = '$now'
        break
pool['lastUpdated'] = '$now'
with open('$POOL_FILE', 'w') as f:
    json.dump(pool, f, indent=2, ensure_ascii=False)
"

  # Output device_id to stdout (for capture by caller)
  echo "$device_id"
}

# ─── release ────────────────────────────────────────────────────────────────

cmd_release() {
  local device_id="$1"
  [[ -z "$device_id" ]] && { echo "Usage: device-pool.sh release <device_id>" >&2; exit 1; }

  local lock_dir="$LOCKS_DIR/${device_id}.lock.d"

  # Read OS from lock info before removing
  local os=""
  if [[ -f "$lock_dir/info.json" ]]; then
    os="$(python3 -c "import json; print(json.load(open('$lock_dir/info.json')).get('os',''))" 2>/dev/null || echo "")"
  fi

  # Remove lock
  rm -rf "$lock_dir"

  # Update pool file if exists
  if [[ -f "$POOL_FILE" ]]; then
    local now
    now="$(timestamp_now)"
    python3 -c "
import json
pool = json.load(open('$POOL_FILE'))
os_list = ['$os'] if '$os' else list(pool.get('devices', {}).keys())
for os_key in os_list:
    for d in pool.get('devices', {}).get(os_key, []):
        if d['id'] == '$device_id':
            d['status'] = 'idle'
            d['lockedBy'] = None
            d['lockedAt'] = None
            break
pool['lastUpdated'] = '$now'
with open('$POOL_FILE', 'w') as f:
    json.dump(pool, f, indent=2, ensure_ascii=False)
" 2>/dev/null || true
  fi

  echo "Released: $device_id"
}

# ─── status ─────────────────────────────────────────────────────────────────

cmd_status() {
  if [[ ! -f "$POOL_FILE" ]]; then
    echo "No device pool found. Run 'device-pool.sh discover' first."
    return
  fi

  python3 -c "
import json

pool = json.load(open('$POOL_FILE'))
print(f\"Last updated: {pool.get('lastUpdated', 'unknown')}\")
print()

for os_name, devices in pool.get('devices', {}).items():
    idle = sum(1 for d in devices if d['status'] == 'idle')
    locked = sum(1 for d in devices if d['status'] == 'locked')
    print(f'[{os_name.upper()}] Total: {len(devices)}, Idle: {idle}, Locked: {locked}')
    print(f\"{'ID':<25} {'Model':<20} {'Status':<10} {'Locked By':<25}\")
    print('-' * 80)
    for d in devices:
        locked_by = d.get('lockedBy') or '-'
        print(f\"{d['id']:<25} {d.get('model','?'):<20} {d['status']:<10} {locked_by:<25}\")
    print()
"
}

# ─── cleanup ────────────────────────────────────────────────────────────────

cmd_cleanup() {
  local cleaned=0
  local now_epoch
  now_epoch="$(epoch_now)"

  for lock_dir in "$LOCKS_DIR"/*.lock.d; do
    [[ -d "$lock_dir" ]] || continue
    [[ -f "$lock_dir/info.json" ]] || { rm -rf "$lock_dir"; cleaned=$((cleaned + 1)); continue; }

    local pid locked_at device_id
    device_id="$(basename "$lock_dir" .lock.d)"
    pid="$(python3 -c "import json; print(json.load(open('$lock_dir/info.json')).get('pid', 0))" 2>/dev/null || echo 0)"
    locked_at="$(python3 -c "import json; print(json.load(open('$lock_dir/info.json')).get('lockedAt', ''))" 2>/dev/null || echo "")"

    local should_clean=false

    # Check if PID is dead
    if [[ "$pid" -gt 0 ]] && ! kill -0 "$pid" 2>/dev/null; then
      should_clean=true
      echo "[cleanup] $device_id: PID $pid is dead"
    fi

    # Check TTL expiry
    if [[ -n "$locked_at" ]] && ! $should_clean; then
      local lock_epoch
      lock_epoch="$(iso_to_epoch "$locked_at")"
      if [[ $((now_epoch - lock_epoch)) -gt $LOCK_TTL_SECONDS ]]; then
        should_clean=true
        echo "[cleanup] $device_id: Lock TTL expired (locked at $locked_at)"
      fi
    fi

    if $should_clean; then
      cmd_release "$device_id" >/dev/null
      cleaned=$((cleaned + 1))
    fi
  done

  echo "[cleanup] Cleaned $cleaned stale lock(s)"
}

# ─── count ──────────────────────────────────────────────────────────────────

cmd_count() {
  local os="$1"
  [[ -z "$os" ]] && { echo "Usage: device-pool.sh count <os>" >&2; exit 1; }

  if [[ ! -f "$POOL_FILE" ]]; then
    echo "0"
    return
  fi

  python3 -c "
import json
pool = json.load(open('$POOL_FILE'))
devices = pool.get('devices', {}).get('$os', [])
idle = sum(1 for d in devices if d['status'] == 'idle')
print(idle)
"
}

# ─── main ───────────────────────────────────────────────────────────────────

case "${1:-}" in
  discover)   cmd_discover ;;
  acquire)    cmd_acquire "$2" "$3" "${4:-$$}" ;;
  release)    cmd_release "$2" ;;
  status)     cmd_status ;;
  cleanup)    cmd_cleanup ;;
  count)      cmd_count "$2" ;;
  -h|--help)  usage ;;
  *)          usage ;;
esac
