#!/usr/bin/env python3
"""
Parse Android JUnit XML test results and output uitest_results.json format.
Extracts errorMessage (from failure/error message attribute) and stackTrace (from element body).
"""
import argparse
import json
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import List, Tuple


def sanitize_for_json(s: str) -> str:
    """Replace control characters that could cause JSON issues. json.dumps escapes \\n \\t \\r etc., but raw control chars (e.g. from XML) may cause problems."""
    if not s:
        return s
    return "".join(c if ord(c) >= 32 or c in "\n\r\t" else " " for c in s)


def derive_test_file_path(className: str, module_name: str) -> str:
    """Convert fully qualified class name to test file path relative to project root."""
    if "." not in className:
        return f"{module_name}/src/androidTest/java/{className}.kt"
    parts = className.rsplit(".", 1)
    package = parts[0]
    class_name = parts[1]
    package_path = package.replace(".", "/")
    return f"{module_name}/src/androidTest/java/{package_path}/{class_name}.kt"


def parse_xml_file(xml_path: Path) -> Tuple[List[dict], int, int]:
    """Parse a single JUnit XML file. Returns (failed_tests, total, passed)."""
    failed_tests = []
    total = 0
    passed = 0

    try:
        tree = ET.parse(xml_path)
        root = tree.getroot()
    except ET.ParseError:
        return [], 0, 0

    # Handle both testsuites (root) and testsuite elements
    suites = []
    if root.tag in ("testsuites", "testsuite"):
        suites = [root] if root.tag == "testsuite" else list(root)
    else:
        for child in root:
            if child.tag == "testsuite":
                suites.append(child)

    for suite in suites:
        total += int(suite.get("tests", 0))
        passed += int(suite.get("tests", 0)) - int(suite.get("failures", 0)) - int(suite.get("errors", 0))

        for testcase in suite.findall(".//testcase"):
            failure = testcase.find("failure")
            error_elem = testcase.find("error")

            fail_elem = failure if failure is not None else error_elem
            if fail_elem is None:
                continue

            classname = testcase.get("classname", "")
            testname = testcase.get("name", "")

            # errorMessage: message attribute, or first line of body, or type
            error_message = fail_elem.get("message") or fail_elem.get("type") or ""
            body_text = "".join(fail_elem.itertext()).strip()
            if not error_message and body_text:
                error_message = body_text.split("\n")[0][:500]

            # stackTrace: full body content (includes stack trace lines)
            stack_trace = body_text
            if fail_elem.get("message") and body_text and fail_elem.get("message") not in body_text:
                # Avoid duplicating message in stackTrace if it's already there
                pass
            if not stack_trace and error_message:
                stack_trace = error_message

            failed_tests.append({
                "className": sanitize_for_json(classname),
                "testName": sanitize_for_json(testname),
                "errorMessage": sanitize_for_json(error_message),
                "stackTrace": sanitize_for_json(stack_trace),
            })

    return failed_tests, total, passed


def main():
    parser = argparse.ArgumentParser(description="Parse Android JUnit XML and output uitest_results.json")
    parser.add_argument("xml_dir", help="Directory containing TEST-*.xml files (e.g. build/outputs/androidTest-results/connected/)")
    parser.add_argument("-o", "--output", required=True, help="Output JSON file path")
    parser.add_argument("-p", "--project-path", required=True, help="Project path (e.g. .gemini/agents/workspace/Yogiyo_Android_for_ai)")
    parser.add_argument("-m", "--module", default="", help="Android module name for testFilePath (auto-detect from path if empty)")
    args = parser.parse_args()

    xml_dir = Path(args.xml_dir)
    module_name = args.module
    if not module_name and "build/outputs" in str(xml_dir):
        # Infer module from path: .../module/build/outputs/androidTest-results/...
        parts = Path(args.xml_dir).parts
        for i, p in enumerate(parts):
            if p == "build" and i > 0:
                module_name = parts[i - 1]
                break
    if not module_name:
        module_name = "yogiyo"
    if not xml_dir.exists():
        print(json.dumps({
            "platform": "android",
            "projectPath": args.project_path,
            "totalCount": 0,
            "passedCount": 0,
            "failedCount": 0,
            "failedTests": [],
        }, indent=2, ensure_ascii=False))
        Path(args.output).write_text(json.dumps({
            "platform": "android",
            "projectPath": args.project_path,
            "totalCount": 0,
            "passedCount": 0,
            "failedCount": 0,
            "failedTests": [],
        }, indent=2, ensure_ascii=False), encoding="utf-8")
        return

    # Find all XML files (including in subdirs like connected/Pixel_3a_API_34/)
    xml_files = list(xml_dir.rglob("TEST-*.xml"))
    if not xml_files:
        xml_files = list(xml_dir.rglob("*.xml"))

    seen = set()
    all_failed = []
    total_count = 0
    passed_count = 0

    for xml_file in xml_files:
        failed, total, passed = parse_xml_file(xml_file)
        total_count = max(total_count, total)
        passed_count = max(passed_count, passed)

        for f in failed:
            key = (f["className"], f["testName"])
            f["testFilePath"] = derive_test_file_path(f["className"], module_name)
            if key not in seen:
                seen.add(key)
                all_failed.append(f)
            else:
                # Keep the entry with longer stackTrace when duplicate (multiple devices)
                for existing in all_failed:
                    if (existing["className"], existing["testName"]) == key:
                        if len(f.get("stackTrace", "")) > len(existing.get("stackTrace", "")):
                            existing.update(f)
                        break

    result = {
        "platform": "android",
        "projectPath": args.project_path,
        "totalCount": total_count,
        "passedCount": max(0, total_count - len(all_failed)),
        "failedCount": len(all_failed),
        "failedTests": all_failed,
    }

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")


if __name__ == "__main__":
    main()
