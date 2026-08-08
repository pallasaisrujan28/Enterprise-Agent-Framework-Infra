"""Print Access Analyzer findings and set the exit code.

The exit code is the point. A validator whose output nobody reads is not a check.

ERROR and SECURITY_WARNING fail. SUGGESTION and WARNING are printed but do not fail:
they are style advice, not correctness.
"""

import json
import sys

FAILING = {"ERROR", "SECURITY_WARNING"}


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: report_findings.py <findings.json> [--expect-failure]", file=sys.stderr)
        return 1

    expect_failure = "--expect-failure" in sys.argv
    findings = json.load(open(sys.argv[1], encoding="utf-8")).get("findings", [])

    blocking = 0
    for f in findings:
        kind = f["findingType"]
        if kind in FAILING:
            blocking += 1
        marker = "FAIL" if kind in FAILING else "note"
        where = ", ".join(
            ".".join(str(p.get("value", p.get("index", "?"))) for p in loc["path"])
            for loc in f.get("locations", [])
        )
        print(f"[{marker}] {kind}: {f['findingDetails']}")
        if where:
            print(f"         at {where}")

    print(f"\n{len(findings)} finding(s), {blocking} blocking")

    if expect_failure:
        # Negative control. Findings are the PASS condition here.
        if blocking:
            print("negative control passed: the validator still rejects bad actions")
            return 0
        print(
            "NEGATIVE CONTROL FAILED: Access Analyzer accepted actions that do not "
            "exist. A clean result on the real policy cannot be trusted.",
            file=sys.stderr,
        )
        return 1

    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main())
