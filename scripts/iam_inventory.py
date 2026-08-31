#!/usr/bin/env python3
"""IAM role inventory and orphan detection.

Two commands, one purpose: make it impossible to lose track of an IAM role.

    inventory  Read every layer's Terraform state and print the roles it manages.
               Generated from state, never hand-maintained, so it cannot disagree
               with what exists.

    orphans    List every role live in the account, subtract those present in any
               layer's state, subtract documented AWS-managed prefixes, and fail
               naming whatever remains.

`orphans` is the one that prevents recurrence. A role created by hand to fix an
incident survives until the next pipeline run, and then the build says its name.

Reads state via `terraform show -json`, so it does not depend on a layer exposing
an outputs contract and works even for layers written before that convention.

    storage-orphans
               Find EBS volumes that no Terraform layer could know about, because
               a controller inside the cluster created them.

               The teardown on 2026-08-31 proved this is needed. `terraform
               destroy` reported 82 resources destroyed and zero errors, and left
               an 8 GiB volume behind: the EBS CSI driver had provisioned it for
               Langfuse's Postgres PVC through the Kubernetes API, so Terraform
               never knew it existed. The StorageClass reclaim policy was Delete,
               but that only fires when the PVC is deleted through the API — and
               the cluster was destroyed with the PVC still in place.

Usage:
    iam_inventory.py inventory       DIR [DIR ...]
    iam_inventory.py orphans         DIR [DIR ...]
    iam_inventory.py storage-orphans

Exit codes:
    0  clean
    1  orphans found, or a layer could not be read
    2  usage error
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

# Roles AWS or Control Tower create and manage. Not ours, never in our state.
#
# Anchored regexes rather than substring matches: a substring allowlist is how an
# attacker-or-accident-named role such as "my-AWSServiceRoleFor-thing" would slip
# through an orphan check.
AWS_MANAGED_PATTERNS = [
    r"^AWSServiceRoleFor\w+$",
    r"^AWSReservedSSO_.+$",
    r"^OrganizationAccountAccessRole$",
    r"^AWSControlTower.*$",
    r"^aws-controltower-.*$",
    r"^stacksets-exec-[0-9a-f]+$",
    r"^AWSAFTExecution$",
    r"^AWSAFTService$",
]

AWS_MANAGED_RE = re.compile("|".join(f"(?:{p})" for p in AWS_MANAGED_PATTERNS))


def is_aws_managed(role_name: str) -> bool:
    return AWS_MANAGED_RE.match(role_name) is not None


def run(cmd: list[str], cwd: Path | None = None) -> str:
    proc = subprocess.run(
        cmd, cwd=cwd, capture_output=True, text=True, check=False
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"command failed: {' '.join(cmd)}\n"
            f"cwd: {cwd}\n"
            f"stderr: {proc.stderr.strip()}"
        )
    return proc.stdout


def walk_values(node: dict) -> list[dict]:
    """Flatten the resource list from `terraform show -json`.

    Resources live under planned_values/values.root_module and recursively under
    child_modules. Roles created through modules/iam-role are always in a child
    module, so a shallow read would find nothing — this is the bug to avoid.
    """
    out: list[dict] = []
    out.extend(node.get("resources", []))
    for child in node.get("child_modules", []):
        out.extend(walk_values(child))
    return out


def roles_in_state(directory: Path) -> list[dict]:
    """Return the IAM roles present in a layer's state."""
    raw = run(["terraform", "show", "-json"], cwd=directory)
    if not raw.strip():
        return []

    doc = json.loads(raw)
    root = doc.get("values", {}).get("root_module")
    if root is None:
        # No state yet: a layer that has never been applied. Not an error.
        return []

    roles = []
    for res in walk_values(root):
        if res.get("type") != "aws_iam_role":
            continue
        values = res.get("values", {}) or {}
        name = values.get("name")
        if not name:
            continue
        tags = values.get("tags") or {}
        roles.append(
            {
                "name": name,
                "arn": values.get("arn", ""),
                "address": res.get("address", ""),
                "layer_dir": str(directory),
                "boundary": values.get("permissions_boundary") or "",
                "owner": tags.get("Owner", ""),
                "purpose": tags.get("Purpose", ""),
                "tag_layer": tags.get("Layer", ""),
                "managed_by_module": tags.get("ManagedByModule", ""),
                "trust_type": tags.get("TrustType", ""),
            }
        )
    return roles


def live_roles() -> list[str]:
    raw = run(
        [
            "aws", "iam", "list-roles",
            "--query", "Roles[].RoleName",
            "--output", "json",
        ]
    )
    return json.loads(raw)


def collect(dirs: list[Path]) -> tuple[list[dict], list[str]]:
    managed: list[dict] = []
    problems: list[str] = []
    for d in dirs:
        if not d.is_dir():
            problems.append(f"{d}: not a directory")
            continue
        if not any(d.glob("*.tf")):
            continue
        try:
            managed.extend(roles_in_state(d))
        except RuntimeError as exc:
            problems.append(str(exc))
    return managed, problems


def cmd_inventory(dirs: list[Path]) -> int:
    managed, problems = collect(dirs)

    if not managed:
        print("No IAM roles found in any layer's state.")
    else:
        width = max(len(r["name"]) for r in managed)
        print(f"{'ROLE':<{width}}  {'LAYER':<14}  {'OWNER':<14}  BOUNDARY")
        print("-" * (width + 50))
        for r in sorted(managed, key=lambda r: r["name"]):
            boundary = "EXEMPT" if not r["boundary"] else r["boundary"].split("/")[-1]
            print(
                f"{r['name']:<{width}}  {r['tag_layer'] or '?':<14}  "
                f"{r['owner'] or '?':<14}  {boundary}"
            )
        print(f"\n{len(managed)} role(s) under Terraform management.")

        unmoduled = [r for r in managed if r["managed_by_module"] != "modules/iam-role"]
        if unmoduled:
            print(
                f"\nWARNING: {len(unmoduled)} role(s) not created via modules/iam-role:"
            )
            for r in sorted(unmoduled, key=lambda r: r["name"]):
                print(f"  - {r['name']}  ({r['address']} in {r['layer_dir']})")
            print(
                "  modules/iam-role is the only sanctioned creation path. "
                "Migrate these so the conventions apply to them too."
            )

    for p in problems:
        print(f"\nERROR: {p}", file=sys.stderr)
    return 1 if problems else 0


def cmd_orphans(dirs: list[Path]) -> int:
    managed, problems = collect(dirs)
    if problems:
        for p in problems:
            print(f"ERROR: {p}", file=sys.stderr)
        print(
            "\nRefusing to report orphans from an incomplete picture: a layer that "
            "could not be read would make its roles look unmanaged.",
            file=sys.stderr,
        )
        return 1

    managed_names = {r["name"] for r in managed}

    try:
        live = live_roles()
    except RuntimeError as exc:
        print(f"ERROR: could not list live roles: {exc}", file=sys.stderr)
        return 1

    orphans = sorted(
        name
        for name in live
        if name not in managed_names and not is_aws_managed(name)
    )

    print(f"live roles:      {len(live)}")
    print(f"in Terraform:    {len(managed_names)}")
    print(f"AWS-managed:     {sum(1 for n in live if is_aws_managed(n))}")
    print(f"orphans:         {len(orphans)}")

    if not orphans:
        print("\nClean: every role is either Terraform-managed or AWS-managed.")
        return 0

    print("\nORPHANED ROLES — live in the account, in no layer's state:\n")
    for name in orphans:
        print(f"  - {name}")
    print(
        "\nEach is either a role created outside Terraform, or a role whose layer "
        "was not passed to this check.\n"
        "Resolve by importing it into the owning layer, deleting it, or adding it "
        "to AWS_MANAGED_PATTERNS with a comment saying which service owns it."
    )
    return 1


def cmd_storage_orphans() -> int:
    """Report EBS volumes created by an in-cluster controller.

    These are never in Terraform state, so the `orphans` command cannot find them
    — it compares against state and would have to call every one of them an
    orphan. They are identified instead by the tags the EBS CSI driver applies.
    """
    try:
        raw = run(
            [
                "aws", "ec2", "describe-volumes",
                "--query", "Volumes[].{id:VolumeId,state:State,size:Size,"
                           "attachments:Attachments,tags:Tags}",
                "--output", "json",
            ]
        )
    except RuntimeError as exc:
        print(f"ERROR: could not list volumes: {exc}", file=sys.stderr)
        return 1

    volumes = json.loads(raw or "[]")

    def tag(vol: dict, key: str) -> str:
        for t in vol.get("tags") or []:
            if t.get("Key") == key:
                return t.get("Value", "")
        return ""

    cluster_provisioned = [
        v for v in volumes
        if tag(v, "kubernetes.io/created-for/pvc/name")
        or tag(v, "ebs.csi.aws.com/cluster-name")
    ]
    detached = [
        v for v in cluster_provisioned
        if not (v.get("attachments") or [])
    ]

    print(f"EBS volumes total          : {len(volumes)}")
    print(f"cluster-provisioned (PVC)  : {len(cluster_provisioned)}")
    print(f"of those, detached         : {len(detached)}")

    if not detached:
        print("\nClean: no detached cluster-provisioned volumes.")
        return 0

    print("\nORPHANED PVC VOLUMES — detached, and invisible to Terraform:\n")
    for v in detached:
        pvc = tag(v, "kubernetes.io/created-for/pvc/name") or "?"
        ns = tag(v, "kubernetes.io/created-for/pvc/namespace") or "?"
        cl = tag(v, "ebs.csi.aws.com/cluster-name") or "?"
        print(f"  - {v['id']}  {v['size']}GiB  {v['state']}")
        print(f"      pvc={ns}/{pvc}  cluster={cl}")
    print(
        "\nA detached PVC volume means a PersistentVolumeClaim was not deleted "
        "through the Kubernetes API before its cluster went away. The "
        "StorageClass reclaim policy only fires on API deletion, so the volume "
        "outlives everything that knew about it.\n"
        "Delete with: aws ec2 delete-volume --volume-id <id>"
    )
    return 1


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2

    command = argv[1]

    if command == "storage-orphans":
        return cmd_storage_orphans()

    if command not in {"inventory", "orphans"} or len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2

    dirs = [Path(a) for a in argv[2:]]
    return cmd_inventory(dirs) if command == "inventory" else cmd_orphans(dirs)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
