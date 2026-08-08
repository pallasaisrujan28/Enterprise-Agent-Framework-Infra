"""Reintroduce three real bugs into a throwaway copy of the policy.

This is a NEGATIVE CONTROL. "0 findings" on the real policy only means something if
the check is capable of failing. Without this, a validator that quietly stopped
working would look identical to a clean policy — and this project has already had two
checks report confidently while measuring the wrong thing.

Each action below was written at some point, and each would have denied NOTHING:

  s3:DeleteAccountPublicAccessBlock   no such action; removal is a Put with all
                                      flags false
  bedrock:Converse                    an API name, not an IAM action; the Converse
                                      API is authorized by InvokeModel
  accessanalyzer:DeleteAnalyzer       the service prefix needs the hyphen
"""

import json
import sys

BAD_ACTION_BY_SID = {
    "DenyS3PublicAccessWeakening": "s3:DeleteAccountPublicAccessBlock",
    "DenyCrossRegionInferenceDispatch": "bedrock:Converse",
    "DenyDisablingSecurityServices": "accessanalyzer:DeleteAnalyzer",
}


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: make_bad_policy.py <in.json> <out.json>", file=sys.stderr)
        return 1

    policy = json.load(open(sys.argv[1], encoding="utf-8"))

    injected = 0
    for statement in policy["Statement"]:
        bad = BAD_ACTION_BY_SID.get(statement.get("Sid"))
        if bad is None:
            continue
        actions = statement.get("Action")
        if actions is None:
            # A NotAction statement. Skip rather than guess.
            continue
        as_list = [actions] if isinstance(actions, str) else list(actions)
        statement["Action"] = as_list + [bad]
        injected += 1

    if injected != len(BAD_ACTION_BY_SID):
        # Fail loudly. If the Sids were renamed, this script would inject nothing and
        # the negative control would silently stop testing anything.
        print(
            f"ERROR: expected to inject {len(BAD_ACTION_BY_SID)} bad actions, "
            f"injected {injected}. Statement Sids may have been renamed.",
            file=sys.stderr,
        )
        return 1

    with open(sys.argv[2], "w", encoding="utf-8") as fh:
        json.dump(policy, fh, indent=2)
        fh.write("\n")

    print(f"injected {injected} known-bad actions into a throwaway copy")
    return 0


if __name__ == "__main__":
    sys.exit(main())
