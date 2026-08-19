"""Validate accounts/register.yaml against the schema rules.

Run by the checks workflow on every push — no AWS credentials needed.
This is the single source of truth for what a valid register entry looks like.
Add new validation rules here rather than duplicating checks across scripts.

Exit 0  all entries are valid.
Exit 1  one or more entries failed validation (errors printed to stderr).
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
from typing import Any

import yaml

# ── field rules ──────────────────────────────────────────────────────────────

NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,49}$")
OU_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 -]{0,127}$")

VALID_ENVIRONMENTS = {"dev", "test", "staging", "prod"}

# Kept in sync with bootstrap/org-structure/variables.tf protected_ou_names.
# Read from the live organization when this list was first written:
#   aws organizations list-organizational-units-for-parent --parent-id <root>
PROTECTED_OUS = {"Sandbox", "Security", "MLOps", "Apps", "Sprint BE", "Clients"}

REQUIRED_FIELDS = {"ou", "environment", "project", "cost_centre", "owner"}


# ── validators ───────────────────────────────────────────────────────────────

def validate_name(name: str) -> list[str]:
    errors = []
    if not NAME_PATTERN.match(name):
        errors.append(
            f"account name '{name}' is invalid — letters, digits and hyphens only, "
            "starting with a letter or digit, 50 chars max"
        )
    return errors


def validate_entry(name: str, entry: Any) -> list[str]:
    errors = []

    if not isinstance(entry, dict):
        return [f"{name}: entry must be a mapping, got {type(entry).__name__}"]

    missing = REQUIRED_FIELDS - entry.keys()
    if missing:
        errors.append(f"{name}: missing required fields: {', '.join(sorted(missing))}")

    env = entry.get("environment", "")
    if env and env not in VALID_ENVIRONMENTS:
        errors.append(
            f"{name}: environment '{env}' is invalid — "
            f"must be one of: {', '.join(sorted(VALID_ENVIRONMENTS))}"
        )

    ou = entry.get("ou", "")
    if ou:
        if not OU_PATTERN.match(ou):
            errors.append(
                f"{name}: OU name '{ou}' is invalid — letters, digits, spaces and "
                "hyphens, 128 chars max"
            )
        elif ou in PROTECTED_OUS:
            errors.append(
                f"{name}: OU '{ou}' belongs to another team and must not be managed "
                f"by this repository. Protected OUs: {', '.join(sorted(PROTECTED_OUS))}"
            )

    return errors


def validate_register(path: pathlib.Path) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        return [f"cannot read {path}: {exc}"]

    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        return [f"{path}: YAML parse error — {exc}"]

    if data is None or data == {}:
        # Empty register is valid — no accounts yet.
        return []

    if not isinstance(data, dict):
        return [f"{path}: expected a YAML mapping at the top level, got {type(data).__name__}"]

    errors: list[str] = []

    for name, entry in data.items():
        errors.extend(validate_name(str(name)))
        errors.extend(validate_entry(str(name), entry))

    return errors


# ── main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(
        description="Validate accounts/register.yaml. Exit 0 = valid, 1 = errors."
    )
    ap.add_argument(
        "register",
        nargs="?",
        default="accounts/register.yaml",
        help="path to the register file (default: accounts/register.yaml)",
    )
    args = ap.parse_args()

    path = pathlib.Path(args.register)
    if not path.exists():
        print(f"ERROR: {path} does not exist", file=sys.stderr)
        return 1

    errors = validate_register(path)

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        print(
            f"\n{len(errors)} validation error(s) in {path}. "
            "Fix the entries above or run the store-email workflow first.",
            file=sys.stderr,
        )
        return 1

    entry_count = 0
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            entry_count = len(data)
    except Exception:
        pass

    print(f"OK — {path} is valid ({entry_count} account(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
