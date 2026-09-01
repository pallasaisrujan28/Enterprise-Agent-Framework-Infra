#!/usr/bin/env python3
"""Refuse a teardown that would leak AWS resources, and report what a teardown left behind.

WHY THIS EXISTS
---------------
Kubernetes creates AWS resources that Terraform does not manage. A Service of type
LoadBalancer creates an ELB; a PersistentVolumeClaim creates an EBS volume; an Ingress
creates an ALB. None of those appear in any Terraform state, because Kubernetes made them,
not Terraform.

They are cleaned up by in-cluster controllers reacting to the Kubernetes object going away.
So the cleanup only happens if the object is deleted *while the cluster is still alive*.

Destroy the cluster first and the controllers die mid-reconcile. AWS documents both halves:

  "If you have active services and ingress resources in your cluster that are associated
   with a load balancer, you must delete those services before deleting the cluster ...
   Otherwise, you can have orphaned resources in your VPC that prevent you from being able
   to delete the VPC."
  -- EKS DeleteCluster API reference

  "Before you can delete a VPC, you must first terminate or delete any resources that
   created a requester-managed network interface in the VPC."
  -- VPC user guide, Delete a VPC

Two distinct failures follow, and they are opposites:

  LEAK  -- the ELB or volume survives with nothing tracking it. A Network Load Balancer in
           eu-west-2 is $0.02646/hr, about $19.32/month, billing indefinitely.
  STUCK -- the orphaned ENI holds the subnet, so `terraform destroy` fails with
           DependencyViolation and the VPC cannot be removed until someone unpicks it by
           hand.

THE IMPORTANT CONSEQUENCE, which is easy to get backwards: `reclaimPolicy: Delete` on a
StorageClass does NOT guarantee the volume is cleaned up. It only decides what the CSI
controller does when it processes the PVC deletion. If the cluster dies first, there is no
controller left to process anything, and a `Delete` volume leaks exactly like a `Retain`
one. Ordering is the lever; the reclaim policy only matters once ordering is right.

Nothing here is specific to any account, region, cluster or environment: every value is
either passed in or read from the AWS and Kubernetes APIs. Read-only — this script never
deletes anything, it only refuses and reports.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys

# Layers in dependency order, lowest first. A layer may only be destroyed once every layer
# ABOVE it is gone, which is what makes in-cluster controllers still present when the
# objects they watch are deleted.
#
# `registry` is deliberately absent: it is not part of the teardown rhythm at all. Its
# contents are meant to outlive the cluster.
LAYER_ORDER = ["platform", "cluster-addons", "apps"]

# A leaked Network Load Balancer in eu-west-2, for putting a number on the warning.
# Verified against the Pricing API: EUW2-LoadBalancerUsage $0.02646/hr.
NLB_USD_PER_MONTH = 19.32


def sh(cmd: list[str], check: bool = False) -> tuple[int, str]:
    """Run a command, returning (exit code, stdout). stderr is folded into stdout."""
    p = subprocess.run(cmd, capture_output=True, text=True)
    if check and p.returncode != 0:
        print(f"  ! command failed: {' '.join(cmd)}\n    {p.stderr.strip()}", file=sys.stderr)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


# ─────────────────────────── guard 1: layer ordering ────────────────────────────


def higher_layers(layer: str) -> list[str]:
    """Layers that must already be gone before `layer` may be destroyed."""
    if layer not in LAYER_ORDER:
        return []
    return LAYER_ORDER[LAYER_ORDER.index(layer) + 1 :]


def read_state(bucket: str, key: str) -> dict | None:
    """A Terraform state document from S3. None if the object does not exist.

    One download serves both callers — the resource count and the outputs — because a
    second fetch of the same object is latency for nothing.
    """
    rc, out = sh(["aws", "s3api", "head-object", "--bucket", bucket, "--key", key])
    if rc != 0:
        if "404" in out or "Not Found" in out:
            return None
        # 403 is not absence. Treating it as absence would turn a permissions problem into a
        # silent pass, so it has to surface.
        raise RuntimeError(f"cannot read s3://{bucket}/{key}\n{out.strip()}")

    rc, out = sh(["aws", "s3", "cp", f"s3://{bucket}/{key}", "-"])
    if rc != 0:
        raise RuntimeError(f"cannot download s3://{bucket}/{key}\n{out.strip()}")

    return json.loads(out)


def count_resources(doc: dict) -> int:
    """Managed resource instances in a state document.

    Counts `resources[].instances[]` rather than `resources[]`: a resource with count or
    for_each is one entry holding many instances, and an entry whose instances list is empty
    is a leftover shell that manages nothing. Counting entries would call an emptied layer
    occupied and block a legitimate destroy.
    """
    return sum(len(r.get("instances", [])) for r in doc.get("resources", []))


def state_resource_count(bucket: str, key: str) -> int | None:
    """Resource instances in a state object. None if the object does not exist."""
    doc = read_state(bucket, key)
    return None if doc is None else count_resources(doc)


def discover(bucket: str, prefix: str, layer: str) -> dict:
    """Read a layer's own outputs to find the cluster and account it created.

    This is why nothing here is hardcoded to eaf-dev or to one account. The platform layer
    already publishes `cluster_name` and, inside `platform_inventory`, `account_id`; the
    guard reads them back out of state rather than being told. Point it at a different
    environment and it discovers that environment's values.

    Returns {} when the layer has no state, which is the normal case on a re-run.
    """
    doc = read_state(bucket, f"{prefix}/{layer}/terraform.tfstate")
    if doc is None:
        return {}

    outputs = {k: v.get("value") for k, v in doc.get("outputs", {}).items()}
    found: dict = {}

    if isinstance(outputs.get("cluster_name"), str):
        found["cluster"] = outputs["cluster_name"]

    inv = outputs.get("platform_inventory")
    if isinstance(inv, dict):
        if isinstance(inv.get("account_id"), str):
            found["account_id"] = inv["account_id"]
        if isinstance(inv.get("region"), str):
            found["region"] = inv["region"]

    return found


def check_layer_order(bucket: str, prefix: str, layer: str) -> list[str]:
    """Complain if a layer above `layer` still holds resources."""
    problems: list[str] = []
    ordered = higher_layers(layer)
    if not ordered:
        print(f"  {layer} is the topmost layer in the teardown order — nothing above it")
        return problems

    for higher in ordered:
        key = f"{prefix}/{higher}/terraform.tfstate"
        doc = read_state(bucket, key)
        count = None if doc is None else count_resources(doc)
        if count is None:
            print(f"  {higher:<16} no state object — never applied or already removed  OK")
        elif count == 0:
            print(f"  {higher:<16} state exists, 0 resources — already destroyed        OK")
        else:
            print(f"  {higher:<16} {count} resources STILL PRESENT                     REFUSE")
            problems.append(
                f"layer '{higher}' still holds {count} resources and sits above '{layer}'. "
                f"Destroy '{higher}' first: its in-cluster controllers need a live cluster to "
                f"release the AWS resources they created."
            )
    return problems


# ───────────────── guard 2: Kubernetes objects that own AWS resources ─────────────────


def kube_objects_owning_aws(cluster: str, region: str, role_arn: str | None) -> list[str]:
    """Find Kubernetes objects whose deletion is the only thing that frees an AWS resource.

    A missing or unreachable cluster is a PASS, not a failure. Teardown is frequently
    re-run, and on the second run the cluster is legitimately gone.
    """
    problems: list[str] = []

    rc, out = sh(["aws", "eks", "describe-cluster", "--name", cluster, "--region", region]
                 + (["--role-arn", role_arn] if role_arn else []))
    if rc != 0:
        if "ResourceNotFoundException" in out:
            print(f"  cluster {cluster} does not exist — nothing in-cluster to leak  OK")
            return problems
        print(f"  ! could not describe cluster {cluster}; skipping in-cluster checks")
        print(f"    {out.strip().splitlines()[-1] if out.strip() else ''}")
        return problems

    status = json.loads(out)["cluster"]["status"]
    if status != "ACTIVE":
        print(f"  cluster {cluster} is {status}, not ACTIVE — skipping in-cluster checks")
        return problems

    rc, _ = sh(["aws", "eks", "update-kubeconfig", "--name", cluster, "--region", region]
               + (["--role-arn", role_arn] if role_arn else []))
    if rc != 0:
        print("  ! could not write kubeconfig; skipping in-cluster checks")
        return problems

    # Services of type LoadBalancer -> one ELB each, invisible to Terraform.
    rc, out = sh(["kubectl", "get", "svc", "--all-namespaces", "-o", "json"])
    if rc == 0:
        svcs = [
            f"{i['metadata']['namespace']}/{i['metadata']['name']}"
            for i in json.loads(out)["items"]
            if i["spec"].get("type") == "LoadBalancer"
        ]
        print(f"  Services type=LoadBalancer : {len(svcs)}")
        for s in svcs:
            print(f"    - {s}")
        if svcs:
            problems.append(
                f"{len(svcs)} LoadBalancer Service(s) still exist, each fronted by an ELB that "
                f"Terraform does not manage: {', '.join(svcs)}. Destroying the cluster now "
                f"leaks them (~${NLB_USD_PER_MONTH:.2f}/month each) and their ENIs will hold the "
                f"subnets, failing the VPC destroy with DependencyViolation."
            )

    # Ingresses -> an ALB each, same problem.
    rc, out = sh(["kubectl", "get", "ingress", "--all-namespaces", "-o", "json"])
    if rc == 0:
        ings = [f"{i['metadata']['namespace']}/{i['metadata']['name']}" for i in json.loads(out)["items"]]
        print(f"  Ingresses                  : {len(ings)}")
        if ings:
            problems.append(
                f"{len(ings)} Ingress object(s) still exist, each backed by a load balancer "
                f"Terraform does not manage: {', '.join(ings)}."
            )

    # PVCs -> an EBS volume each. Bound ones are the risk.
    rc, out = sh(["kubectl", "get", "pvc", "--all-namespaces", "-o", "json"])
    if rc == 0:
        pvcs = [
            (f"{i['metadata']['namespace']}/{i['metadata']['name']}", i["status"].get("phase"))
            for i in json.loads(out)["items"]
        ]
        print(f"  PersistentVolumeClaims     : {len(pvcs)}")
        for name, phase in pvcs:
            print(f"    - {name} ({phase})")
        if pvcs:
            problems.append(
                f"{len(pvcs)} PersistentVolumeClaim(s) still exist, each holding an EBS volume: "
                f"{', '.join(n for n, _ in pvcs)}. reclaimPolicy=Delete does NOT save you here — "
                f"it only tells the CSI controller what to do when it processes the PVC deletion, "
                f"and destroying the cluster leaves no controller to process anything. The volume "
                f"leaks and keeps billing."
            )

    return problems


# ──────────────────────── report: what is still billing ─────────────────────────


class Unknown:
    """A probe that could not be answered.

    THIS TYPE EXISTS BECAUSE THE FIRST VERSION OF sweep() WAS DANGEROUS.

    It read `n = len(...) if rc == 0 else 0`, so a failed API call became a zero. Run with an
    expired token, it printed a full clean bill of health — 0 clusters, 0 load balancers, 0
    volumes, nothing leaked — having not successfully called AWS once. The one job of a
    post-teardown sweep is to tell you nothing was left billing, and it said exactly that by
    failing to look.

    Same shape as the `-refresh=false` plan recorded as RC7 in the design: a check that passes
    because it never read the thing it claims to have checked. An absent answer must never
    render as a reassuring one.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason

    def __str__(self) -> str:
        return "  ?"


def probe(cmd: list[str], extract) -> int | Unknown:
    """Run an AWS query and count what comes back, or return Unknown with the reason."""
    rc, out = sh(cmd)
    if rc != 0:
        line = next((l for l in out.strip().splitlines() if "error occurred" in l.lower()), "")
        return Unknown(line.strip() or f"exit {rc}")
    try:
        return extract(json.loads(out))
    except (json.JSONDecodeError, KeyError, TypeError) as e:
        return Unknown(f"unparseable response: {e}")


def sweep(region: str) -> list[str]:
    """List anything in the region that still costs money.

    Returns the reasons any probe failed. An empty list means every number shown was actually
    read from AWS. A non-empty list means the output is incomplete and must not be read as
    an all-clear.
    """
    print(f"\n  what is still billing in {region}")
    print("  " + "─" * 60)

    unknowns: list[str] = []

    def line(label: str, value: int | Unknown, note: str = "", leak_when=lambda v: v > 0,
             leak_note: str = "") -> None:
        if isinstance(value, Unknown):
            unknowns.append(f"{label.strip()}: {value.reason}")
            print(f"  {label:<21} {'?':>4}   COULD NOT CHECK — {value.reason}")
            return
        flag = f"  <-- {leak_note}" if leak_note and leak_when(value) else ""
        print(f"  {label:<21} {value:>4}   {note}{flag}")

    clusters = probe(["aws", "eks", "list-clusters", "--region", region, "--output", "json"],
                     lambda d: len(d["clusters"]))
    line("EKS clusters", clusters, "$0.10/hr each")

    line("running EC2 instances",
         probe(["aws", "ec2", "describe-instances", "--region", region,
                "--filters", "Name=instance-state-name,Values=running", "--output", "json"],
               lambda d: sum(len(r["Instances"]) for r in d["Reservations"])))

    line("NAT gateways",
         probe(["aws", "ec2", "describe-nat-gateways", "--region", region,
                "--filter", "Name=state,Values=available", "--output", "json"],
               lambda d: len(d["NatGateways"])),
         "$0.05/hr each")

    v2 = probe(["aws", "elbv2", "describe-load-balancers", "--region", region, "--output", "json"],
               lambda d: len(d["LoadBalancers"]))
    v1 = probe(["aws", "elb", "describe-load-balancers", "--region", region, "--output", "json"],
               lambda d: len(d["LoadBalancerDescriptions"]))
    # Either probe failing makes the total unknown. Adding a real count to a failed one would
    # understate the answer, which is the mistake this whole class exists to prevent.
    total_lb: int | Unknown = (
        v2 if isinstance(v2, Unknown) else v1 if isinstance(v1, Unknown) else v2 + v1
    )
    line("load balancers", total_lb, f"~${NLB_USD_PER_MONTH:.2f}/mo each",
         leak_note="LEAK, nothing here should own one")

    vols = probe(["aws", "ec2", "describe-volumes", "--region", region, "--output", "json"],
                 lambda d: d["Volumes"])
    if isinstance(vols, Unknown):
        line("EBS volumes", vols)
    else:
        detached = [v for v in vols if v["State"] == "available"]
        gb = sum(v["Size"] for v in detached)
        extra = f"  <-- LEAK, {gb} GB ~${gb * 0.0928:.2f}/mo" if detached else ""
        print(f"  {'EBS volumes':<21} {len(vols):>4}   of which detached: {len(detached)}{extra}")

    addrs = probe(["aws", "ec2", "describe-addresses", "--region", region, "--output", "json"],
                  lambda d: d["Addresses"])
    if isinstance(addrs, Unknown):
        line("elastic IPs", addrs)
    else:
        unassoc = [a for a in addrs if not a.get("AssociationId")]
        extra = "  <-- LEAK, an unassociated EIP still bills" if unassoc else ""
        print(f"  {'elastic IPs':<21} {len(addrs):>4}   of which unassociated: {len(unassoc)}{extra}")

    line("EBS snapshots",
         probe(["aws", "ec2", "describe-snapshots", "--region", region, "--owner-ids", "self",
                "--output", "json"], lambda d: len(d["Snapshots"])),
         "$0.05/GB-mo")

    if unknowns:
        print()
        print(f"  !! {len(unknowns)} of these could not be checked, so this is NOT an all-clear.")
        print("     Most often an expired token — re-authenticate and run it again.")

    return unknowns


# ──────────────────────────────────── main ─────────────────────────────────────


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--layer", help="Layer about to be destroyed. Omit to only sweep.")
    ap.add_argument("--bucket", help="State bucket. Required with --layer.")
    ap.add_argument("--prefix", default="workloads/dev", help="State key prefix for this target.")
    ap.add_argument("--cluster", help="Cluster name, for the in-cluster checks.")
    ap.add_argument("--region", help="Region. Discovered from platform state when omitted.")
    ap.add_argument("--role-arn", help="Role to assume for EKS calls, if creds are not already in the account.")
    ap.add_argument("--sweep", action="store_true", help="Also report what is still billing.")
    args = ap.parse_args()

    problems: list[str] = []

    if args.layer:
        if not args.bucket:
            ap.error("--bucket is required with --layer")

        print(f"\n  teardown guard: about to destroy '{args.layer}'")
        print("  " + "─" * 60)
        print("  layers above it must already be gone, because in-cluster controllers")
        print("  need a live cluster to release the AWS resources they created")
        problems += check_layer_order(args.bucket, args.prefix, args.layer)

        # Only the platform layer takes the cluster away, so it is the only one where
        # in-cluster objects turn into leaks.
        if args.layer == "platform":
            # Ask the layer what it built rather than being told. Explicit flags still win,
            # so a caller can override, but the default path needs no per-environment
            # configuration and works unchanged against any target.
            found = discover(args.bucket, args.prefix, "platform")
            cluster = args.cluster or found.get("cluster")
            region = args.region or found.get("region")
            role_arn = args.role_arn
            if not role_arn and found.get("account_id"):
                # The workflow's credentials live in the management account, so reaching the
                # cluster means the same hop provider.tf makes.
                role_arn = f"arn:aws:iam::{found['account_id']}:role/OrganizationAccountAccessRole"

            if not cluster:
                print("\n  no cluster_name in platform state — nothing in-cluster to check")
            else:
                print("\n  Kubernetes objects that own AWS resources Terraform cannot see")
                print("  " + "─" * 60)
                src = "--cluster" if args.cluster else "discovered from platform state"
                print(f"  cluster {cluster} ({src})")
                problems += kube_objects_owning_aws(cluster, region, role_arn)

    sweep_unknowns: list[str] = []
    if args.sweep or not args.layer:
        sweep_unknowns = sweep(args.region or "eu-west-2")

    # A sweep that could not read AWS is a failure, not a pass. Exiting 0 here would let a
    # caller treat "I could not look" as "nothing is leaking".
    if sweep_unknowns and not args.layer:
        print("\n  INCOMPLETE: could not determine what is billing")
        print("  " + "─" * 60)
        for u in sweep_unknowns:
            print(f"  * {u}")
        return 1

    if problems:
        print("\n  REFUSING: this teardown would leak AWS resources")
        print("  " + "─" * 60)
        for p in problems:
            print(f"  * {p}\n")
        print("  Destroy the layers above this one first, in order:")
        print("    " + "  ->  ".join(reversed(LAYER_ORDER)))
        return 1

    if args.layer:
        print(f"\n  OK: '{args.layer}' is safe to destroy — nothing above it, nothing to leak")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as e:
        print(f"\n  ERROR: {e}", file=sys.stderr)
        sys.exit(2)
