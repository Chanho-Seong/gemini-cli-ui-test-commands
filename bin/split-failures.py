#!/usr/bin/env python3
"""
split-failures.py — aggregated UITest 결과의 failedTests를 N개 shard로 round-robin 분할

Usage:
    python3 bin/split-failures.py --input <aggregated.json> --num-shards N --output-dir <dir>

Output:
    <dir>/verify_shard_0_uitest_results.json
    <dir>/verify_shard_1_uitest_results.json
    ...
"""

import argparse
import json
import os
import sys


def main():
    parser = argparse.ArgumentParser(description="Split failedTests into N shards")
    parser.add_argument("--input", required=True, help="Path to all_uitest_results.json")
    parser.add_argument("--num-shards", type=int, required=True, help="Number of shards")
    parser.add_argument("--output-dir", required=True, help="Directory for shard output files")
    args = parser.parse_args()

    with open(args.input) as f:
        data = json.load(f)

    failed_tests = data.get("failedTests", [])
    num_shards = max(1, min(args.num_shards, len(failed_tests)))

    os.makedirs(args.output_dir, exist_ok=True)

    # Round-robin 분배
    shards = [[] for _ in range(num_shards)]
    for i, test in enumerate(failed_tests):
        shards[i % num_shards].append(test)

    # 공통 필드 복사 (failedTests, failedCount 제외)
    base = {k: v for k, v in data.items() if k not in ("failedTests", "failedCount")}

    for idx, shard in enumerate(shards):
        shard_data = {**base, "failedCount": len(shard), "failedTests": shard}
        output_path = os.path.join(args.output_dir, f"verify_shard_{idx}_uitest_results.json")
        with open(output_path, "w") as f:
            json.dump(shard_data, f, indent=2, ensure_ascii=False)
        print(f"Shard {idx}: {len(shard)} failures -> {output_path}")

    print(f"Split {len(failed_tests)} failures into {num_shards} shard(s)")


if __name__ == "__main__":
    main()
