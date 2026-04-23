#!/usr/bin/env bash
#
# device-select.sh — 특정 에뮬레이터/시뮬레이터를 선택/고정하고 후속 단계에서 재사용
#
# 서브커맨드:
#   list <android|ios>                   # 연결된 디바이스 목록 JSON 출력
#   pin <android|ios> <device_id> [--build-dir <dir>]
#                                        # 디바이스 고정 (상태 파일 기록)
#   current [--build-dir <dir>]          # 현재 고정된 디바이스 id 출력 (없으면 exit 1)
#   clear [--build-dir <dir>]            # 고정 해제
#   info [--build-dir <dir>]             # 상태 파일 전체 JSON 출력
#
# 상태 파일: <build-dir>/state/selected_device.json
#   { "platform": "android", "deviceId": "emulator-5554", "model": "...", "pinnedAt": "..." }
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '3,18p' "$0"
}

resolve_build_dir() {
  local arg_value=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --build-dir) arg_value="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [[ -n "$arg_value" ]]; then
    echo "$arg_value"
  else
    bash "$SCRIPT_DIR/resolve-build-dir.sh"
  fi
}

list_android() {
  local output
  output="$(adb devices -l 2>/dev/null || true)"
  python3 - <<PY "$output"
import json, sys
raw = sys.argv[1]
devices = []
for line in raw.splitlines():
    line = line.strip()
    if not line or line.startswith('List of devices'):
        continue
    parts = line.split()
    if len(parts) < 2:
        continue
    dev_id, state = parts[0], parts[1]
    meta = {}
    for token in parts[2:]:
        if ':' in token:
            k, v = token.split(':', 1)
            meta[k] = v
    devices.append({
        'id': dev_id,
        'state': state,
        'model': meta.get('model', ''),
        'product': meta.get('product', ''),
        'transport': meta.get('transport_id', ''),
    })
print(json.dumps(devices, indent=2, ensure_ascii=False))
PY
}

list_ios() {
  # booted 시뮬레이터 + 연결된 실기기 모두 수집
  local simctl_json
  simctl_json="$(xcrun simctl list devices booted -j 2>/dev/null || echo '{"devices":{}}')"
  local physical
  physical="$(xcrun xctrace list devices 2>&1 | grep -E '\([0-9A-F-]{25,}\)' | grep -v Simulator || true)"
  python3 - <<PY "$simctl_json" "$physical"
import json, sys, re
simctl_raw, physical = sys.argv[1], sys.argv[2]
devices = []
try:
    data = json.loads(simctl_raw)
except Exception:
    data = {}
for runtime, items in (data.get('devices') or {}).items():
    for it in items:
        if it.get('state') == 'Booted':
            devices.append({
                'id': it.get('udid',''),
                'name': it.get('name',''),
                'state': 'Booted',
                'type': 'simulator',
                'runtime': runtime.split('.')[-1],
            })
for line in physical.splitlines():
    m = re.match(r'^(.*?)\s*\(([\d.]+)\)\s*\(([0-9A-F-]{25,})\)', line.strip())
    if m:
        devices.append({
            'id': m.group(3),
            'name': m.group(1),
            'osVersion': m.group(2),
            'state': 'Connected',
            'type': 'physical',
        })
print(json.dumps(devices, indent=2, ensure_ascii=False))
PY
}

cmd_list() {
  local platform="${1:-}"
  case "$platform" in
    android) list_android ;;
    ios)     list_ios ;;
    *) echo "usage: device-select.sh list <android|ios>" >&2; exit 2 ;;
  esac
}

cmd_pin() {
  local platform="$1"; shift || true
  local device_id="$1"; shift || true
  local build_dir
  build_dir="$(resolve_build_dir "$@")"

  [[ -z "$platform" || -z "$device_id" ]] && { echo "usage: device-select.sh pin <platform> <device_id>" >&2; exit 2; }

  mkdir -p "$build_dir/state"
  local state_file="$build_dir/state/selected_device.json"

  # 모델 정보 추가 조회
  local model="" name=""
  if [[ "$platform" == "android" ]]; then
    model="$(adb -s "$device_id" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || echo '')"
  else
    name="$(xcrun simctl list devices 2>/dev/null | grep -F "$device_id" | sed -E 's/^[[:space:]]*([^(]+) \(.*/\1/' | head -1 | xargs || echo '')"
  fi

  python3 - "$state_file" "$platform" "$device_id" "$model" "$name" <<'PY'
import json, sys, datetime
path, platform, dev_id, model, name = sys.argv[1:6]
payload = {
    'platform': platform,
    'deviceId': dev_id,
    'model': model,
    'name': name,
    'pinnedAt': datetime.datetime.utcnow().replace(microsecond=0).isoformat() + 'Z',
}
with open(path, 'w', encoding='utf-8') as f:
    json.dump(payload, f, indent=2, ensure_ascii=False)
print(json.dumps(payload, indent=2, ensure_ascii=False))
PY
}

cmd_current() {
  local build_dir
  build_dir="$(resolve_build_dir "$@")"
  local state_file="$build_dir/state/selected_device.json"
  if [[ ! -f "$state_file" ]]; then
    echo "" >&2
    exit 1
  fi
  python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['deviceId'])" "$state_file"
}

cmd_clear() {
  local build_dir
  build_dir="$(resolve_build_dir "$@")"
  local state_file="$build_dir/state/selected_device.json"
  rm -f "$state_file"
  echo "cleared: $state_file"
}

cmd_info() {
  local build_dir
  build_dir="$(resolve_build_dir "$@")"
  local state_file="$build_dir/state/selected_device.json"
  if [[ -f "$state_file" ]]; then
    cat "$state_file"
  else
    echo '{}'
  fi
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    list)    cmd_list "$@" ;;
    pin)     cmd_pin "$@" ;;
    current) cmd_current "$@" ;;
    clear)   cmd_clear "$@" ;;
    info)    cmd_info "$@" ;;
    -h|--help|'') usage ;;
    *) echo "unknown subcommand: $sub" >&2; usage; exit 2 ;;
  esac
}

main "$@"
