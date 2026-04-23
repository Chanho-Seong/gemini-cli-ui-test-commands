#!/usr/bin/env python3
"""
summary-report.py — UI Test Loop 의 각 단계 결과 JSON 을 통합하여
<build-dir>/summary.md 로 마크다운 최종 리포트 생성.

사용법:
  python3 summary-report.py <build-dir>
"""

import json
import os
import sys
from datetime import datetime


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def fmt_selection_filter(sf):
    if not sf:
        return "전체 테스트"
    parts = []
    classes = sf.get("classes") or []
    if classes:
        parts.append("classes=" + ", ".join(classes))
    if sf.get("suite"):
        parts.append(f"suite={sf['suite']}")
    if sf.get("method"):
        parts.append(f"method={sf['method']}")
    return " | ".join(parts) if parts else "전체 테스트"


def main():
    if len(sys.argv) < 2:
        print("usage: summary-report.py <build-dir>", file=sys.stderr)
        sys.exit(2)

    build_dir = sys.argv[1]
    logs = os.path.join(build_dir, "logs")
    retest = os.path.join(build_dir, "retest")
    state = os.path.join(build_dir, "state")

    initial = load_json(os.path.join(logs, "all_uitest_results.json"))
    verification = load_json(os.path.join(logs, "device_verification.json"))
    fix_report = load_json(os.path.join(logs, "fix_report.json"))
    retest_result = load_json(os.path.join(retest, "all_uitest_results.json"))
    device = load_json(os.path.join(state, "selected_device.json"))

    lines = []
    lines.append("# UI Test Loop — 실행 리포트")
    lines.append("")
    lines.append(f"- 생성: {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}")
    if device:
        lines.append(f"- 디바이스: `{device.get('deviceId','')}` ({device.get('model') or device.get('name') or ''}) — {device.get('platform','')}")
    else:
        lines.append("- 디바이스: (기록 없음)")
    if initial:
        lines.append(f"- 테스트 범위: {fmt_selection_filter(initial.get('selectionFilter'))}")
    lines.append("")

    # 1차 실행
    lines.append("## 1. 1차 테스트 실행")
    if initial is None:
        lines.append("- 결과 파일 없음")
    else:
        lines.append(f"- 총 {initial.get('totalCount',0)}개 / 통과 {initial.get('passedCount',0)} / 실패 {initial.get('failedCount',0)}")
        if initial.get("error"):
            lines.append(f"- 에러: `{initial['error']}`")
        for ft in (initial.get("failedTests") or [])[:20]:
            lines.append(f"  - ❌ `{ft.get('className')}#{ft.get('testName')}` — {(ft.get('errorMessage') or '').splitlines()[0][:120]}")
    lines.append("")

    # AI Verify
    lines.append("## 2. AI Verify (실단말 재현)")
    if verification is None:
        lines.append("- 검증 생략 또는 결과 없음")
    else:
        vf = verification.get("verifiedFailures") or []
        vp = verification.get("verifiedPasses") or []
        lines.append(f"- 실제 실패로 재현 {len(vf)}건 / 환경차로 통과 {len(vp)}건")
        for f in vf[:20]:
            note = (f.get("verificationNote") or "")[:100]
            lines.append(f"  - 🔴 `{f.get('className')}#{f.get('testName')}` — {note}")
        for p in vp[:10]:
            note = (p.get("verificationNote") or "")[:100]
            lines.append(f"  - 🟢 `{p.get('className')}#{p.get('testName')}` (환경차) — {note}")
    lines.append("")

    # Fix
    lines.append("## 3. 코드 수정")
    if fix_report is None:
        lines.append("- 수정 리포트 없음")
    else:
        files = fix_report.get("filesModified") or []
        fixes = fix_report.get("fixedTests") or []
        lines.append(f"- 수정된 파일 {len(files)}개 / 수정된 테스트 {len(fixes)}건 / 상태 `{fix_report.get('status','')}`")
        for f in files:
            lines.append(f"  - 📝 `{f}`")
        for fx in fixes[:20]:
            cause = (fx.get("rootCause") or "")[:140]
            lines.append(f"  - ✅ `{fx.get('testName')}` — {cause} (commit `{fx.get('commitHash','')[:12]}`)")
    lines.append("")

    # Retest
    lines.append("## 4. 재테스트")
    if retest_result is None:
        lines.append("- 재테스트 실행 안됨")
    else:
        lines.append(f"- 총 {retest_result.get('totalCount',0)}개 / 통과 {retest_result.get('passedCount',0)} / 실패 {retest_result.get('failedCount',0)}")
        for ft in (retest_result.get("failedTests") or [])[:20]:
            lines.append(f"  - ⚠️ `{ft.get('className')}#{ft.get('testName')}` (여전히 실패) — {(ft.get('errorMessage') or '').splitlines()[0][:120]}")
    lines.append("")

    # needs_review
    needs_review = []
    if fix_report and fix_report.get("status") in ("needs_review", "failed"):
        needs_review.append(f"- fix_report 상태: `{fix_report.get('status')}`")
    if retest_result and (retest_result.get("failedCount") or 0) > 0:
        needs_review.append("- 재테스트에서 여전히 실패한 케이스가 있음 — 수동 검토 필요")
    if needs_review:
        lines.append("## 5. 추가 검토 필요")
        lines.extend(needs_review)
        lines.append("")

    content = "\n".join(lines)
    out = os.path.join(build_dir, "summary.md")
    os.makedirs(build_dir, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write(content + "\n")

    print(content)
    print(f"\n[summary-report] wrote: {out}")


if __name__ == "__main__":
    main()
