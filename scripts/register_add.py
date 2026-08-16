"""Append an account to accounts/register.yaml, safely.

Run by the request-account workflow. Validates first, refuses duplicates, and preserves
the file's leading comment block, which carries the "do not edit by hand" warning and
the reasoning about emails.

Deliberately does NOT write the email anywhere. That goes to SSM Parameter Store, in a
separate step, because an account's email becomes its root user and only recovery
address and must stay out of git history.
"""

from __future__ import annotations

import argparse
import datetime as dt
import pathlib
import re
import sys

import yaml

# AWS account names: 1-50 chars. Restricted further than AWS requires so a name is
# usable as an SSM path segment, a Terraform map key and a tag value without escaping.
NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,49}$")
ENVIRONMENTS = ("dev", "test", "staging", "prod")

# AWS allows spaces in OU names - "Sprint BE" is one of the existing ones.
OU_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 -]{0,127}$")

# Must match protected_ou_names in bootstrap/org-structure/variables.tf. Read from the
# live organization, not invented:
#   aws organizations list-organizational-units-for-parent --parent-id <root>
PROTECTED_OUS = ("Sandbox", "Security", "MLOps", "Apps", "Sprint BE", "Clients")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--register", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--ou", required=True)
    ap.add_argument("--cost-centre", required=True, dest="cost_centre")
    ap.add_argument("--environment", required=True)
    ap.add_argument("--project", required=True)
    ap.add_argument("--owner", required=True)
    ap.add_argument("--ticket", default="")
    ap.add_argument("--description", default="")
    args = ap.parse_args()

    if not NAME_PATTERN.match(args.name):
        return fail(
            f"account name {args.name!r} is invalid. Letters, digits and hyphens, "
            "starting with a letter or digit, 50 characters maximum."
        )

    if args.environment not in ENVIRONMENTS:
        return fail(f"environment must be one of {', '.join(ENVIRONMENTS)}")

    if not OU_PATTERN.match(args.ou):
        return fail(
            f"OU name {args.ou!r} is invalid. Letters, digits, spaces and hyphens, "
            "128 characters maximum."
        )

    # Refused here as well as in Terraform. Terraform's check block catches it at plan
    # time, but rejecting it before an SSM parameter is written and a pull request opened
    # is cheaper than unpicking both.
    if args.ou in PROTECTED_OUS:
        return fail(
            f"{args.ou} belongs to another team and must not be managed by this "
            f"repository. Protected: {', '.join(PROTECTED_OUS)}."
        )

    path = pathlib.Path(args.register)
    text = path.read_text(encoding="utf-8")
    register = yaml.safe_load(text) or {}

    if args.name in register:
        # Not an error worth guessing around. An AWS account cannot be recreated and its
        # name is its identity here.
        return fail(
            f"{args.name} is already in the register. Account names cannot be reused, "
            "and an existing account cannot be re-provisioned."
        )

    # Preserve the comment header. yaml.safe_dump would discard every comment in the
    # file, including the instruction not to edit it by hand.
    header_lines = []
    for line in text.splitlines(keepends=True):
        if line.startswith("#") or not line.strip():
            header_lines.append(line)
        else:
            break
    header = "".join(header_lines)

    entry = {
        args.name: {
            "ou": args.ou,
            "environment": args.environment,
            "cost_centre": args.cost_centre,
            "project": args.project,
            "owner": args.owner,
            "requested": dt.date.today().isoformat(),
            "ticket": args.ticket,
            "description": args.description,
        }
    }

    # An empty register must produce an EMPTY string, not "{}". `yaml.safe_dump({})`
    # returns "{}\n", and a flow mapping followed by a block mapping is invalid YAML, so
    # the next request would fail to parse the file.
    body = yaml.safe_dump(register, sort_keys=True, default_flow_style=False) if register else ""
    new_body = yaml.safe_dump(entry, sort_keys=True, default_flow_style=False)

    path.write_text(f"{header}{body}\n{new_body}", encoding="utf-8")

    # Re-read and confirm, rather than trusting the write. A malformed register fails the
    # Terraform plan later with a much less helpful message.
    check = yaml.safe_load(path.read_text(encoding="utf-8"))
    if args.name not in check:
        return fail("wrote the register but the new entry is not readable back")
    if len(check) != len(register) + 1:
        return fail(
            f"register had {len(register)} entries and now has {len(check)}, expected "
            f"{len(register) + 1}. Refusing to continue."
        )

    print(f"added {args.name} to the register ({len(check)} accounts total)")
    return 0


def fail(message: str) -> int:
    print(f"ERROR: {message}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
