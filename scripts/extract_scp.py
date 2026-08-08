"""Pull the planned SCP body out of `terraform show -json` output.

Rendering from a plan rather than reading the HCL is the point. Access Analyzer
validates JSON, and JSON is what AWS enforces. Reading HCL by eye is how three
nonexistent-action bugs got in.

`terraform console` does not work for this: it reads data sources out of state, and
with no state yet it answers "(known after apply)".
"""

import json
import sys

ADDRESS = "aws_organizations_policy.workloads_guardrails"
SCP_CHARACTER_LIMIT = 5120


def main() -> int:
    if len(sys.argv) != 3:
        return exit_with("usage: extract_scp.py <plan.json> <out.json>")

    plan = json.load(open(sys.argv[1], encoding="utf-8"))

    changes = [c for c in plan.get("resource_changes", []) if c["address"] == ADDRESS]
    if not changes:
        return exit_with(f"{ADDRESS} not present in the plan")

    after = changes[0]["change"]["after"]
    if after is None:
        return exit_with(f"{ADDRESS} is being destroyed, nothing to validate")

    content = after.get("content")
    if content is None:
        # Unknown at plan time means something it depends on is unresolved. Failing
        # is correct: validating nothing and reporting success is the worse outcome.
        return exit_with(f"{ADDRESS}.content is unknown in the plan, cannot validate")

    policy = json.loads(content)

    with open(sys.argv[2], "w", encoding="utf-8") as fh:
        json.dump(policy, fh, indent=2)
        fh.write("\n")

    compact = json.dumps(policy, separators=(",", ":"))
    sids = [s.get("Sid", "<no sid>") for s in policy["Statement"]]

    print(f"statements={len(sids)} chars={len(compact)} (SCP limit {SCP_CHARACTER_LIMIT})")
    for sid in sids:
        print(f"  - {sid}")

    if len(compact) > SCP_CHARACTER_LIMIT:
        return exit_with(
            f"policy is {len(compact)} chars, over the {SCP_CHARACTER_LIMIT} limit. "
            "AWS rejects this at attach time."
        )

    return 0


def exit_with(message: str) -> int:
    print(f"ERROR: {message}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
