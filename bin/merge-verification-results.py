#!/usr/bin/env python3
"""
merge-verification-results.py — 여러 verifier-agent의 device_verification.json 결과를 하나로 병합

Usage:
    python3 bin/merge-verification-results.py --dir <logs_dir> --output <output.json> [--aggregated <aggregated.json>]

병합 규칙:
    - 모든 verifiedFailures, verifiedPasses를 합산
    - deviceId: 사용된 디바이스 ID들을 콤마로 연결
    - projectPath: 첫 번째 비어있지 않은 값 사용
    - --aggregated 지정 시, 누락된 테스트(agent 실패로 결과 미생성)를 verifiedFailures에 추가
"""

import argparse
import glob
import json
import os
import sys


def main():
    parser = argparse.ArgumentParser(description="Merge verification results")
    parser.add_argument("--dir", required=True, help="Directory containing *_device_verification.json files")
    parser.add_argument("--output", required=True, help="Output merged JSON path")
    parser.add_argument("--aggregated", default=None, help="Original aggregated results for fallback on missing shards")
    args = parser.parse_args()

    pattern = os.path.join(args.dir, "*_device_verification.json")
    output_abs = os.path.abspath(args.output)
    files = [f for f in sorted(glob.glob(pattern)) if os.path.abspath(f) != output_abs]

    if not files:
        print(f"WARNING: No *_device_verification.json files found in {args.dir}", file=sys.stderr)
        # Fallback: aggregated 파일이 있으면 모든 실패를 verifiedFailures로 전달
        if args.aggregated and os.path.exists(args.aggregated):
            with open(args.aggregated) as f:
                agg = json.load(f)
            merged = {
                "deviceId": "none",
                "projectPath": agg.get("projectPath", ""),
                "verifiedFailures": [
                    {**t, "deviceResult": "SKIPPED", "verificationNote": "Verification agent failed — passing to coder"}
                    for t in agg.get("failedTests", [])
                ],
                "verifiedPasses": [],
            }
            with open(args.output, "w") as f:
                json.dump(merged, f, indent=2, ensure_ascii=False)
            print(f"Fallback: wrote {len(merged['verifiedFailures'])} failures to {args.output}")
            return
        sys.exit(1)

    device_ids = []
    project_path = ""
    all_failures = []
    all_passes = []
    verified_keys = set()

    for fpath in files:
        try:
            with open(fpath) as f:
                data = json.load(f)
        except (json.JSONDecodeError, IOError) as e:
            print(f"WARNING: Failed to read {fpath}: {e}", file=sys.stderr)
            continue

        did = data.get("deviceId", "")
        if did and did not in device_ids:
            device_ids.append(did)

        if not project_path:
            project_path = data.get("projectPath", "")

        for item in data.get("verifiedFailures", []):
            key = (item.get("className", ""), item.get("testName", ""))
            if key not in verified_keys:
                verified_keys.add(key)
                all_failures.append(item)

        for item in data.get("verifiedPasses", []):
            key = (item.get("className", ""), item.get("testName", ""))
            if key not in verified_keys:
                verified_keys.add(key)
                all_passes.append(item)

    # 누락된 테스트 처리 (agent 실패로 결과가 없는 경우)
    if args.aggregated and os.path.exists(args.aggregated):
        with open(args.aggregated) as f:
            agg = json.load(f)
        for test in agg.get("failedTests", []):
            key = (test.get("className", ""), test.get("testName", ""))
            if key not in verified_keys:
                all_failures.append({
                    **test,
                    "deviceResult": "SKIPPED",
                    "verificationNote": "Verification agent failed — passing to coder",
                })

    merged = {
        "deviceId": ",".join(device_ids) if device_ids else "none",
        "projectPath": project_path,
        "verifiedFailures": all_failures,
        "verifiedPasses": all_passes,
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, "w") as f:
        json.dump(merged, f, indent=2, ensure_ascii=False)

    print(f"Merged {len(files)} file(s): {len(all_failures)} failures, {len(all_passes)} passes -> {args.output}")


if __name__ == "__main__":
    main()
