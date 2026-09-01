#!/usr/bin/env python3
"""Verification for scripts/teardown_guard.py.

The guard's whole value is that it says NO at the right moment. An unverified guard is worse
than no guard, because it produces confidence without protection — so the refusal paths are
tested, not just the happy ones.

Every AWS and kubectl call is replaced with fabricated output. That is legitimate here in a
way it is not for a Terraform provider: the logic under test is this script's own, so
fabricated input exercises the real decision. Nothing here asserts what the AWS API accepts.

A NOTE ON THE STUB, because the first version of this file was wrong in an instructive way.
It matched a single substring per stub, and `state_resource_count` makes TWO calls that both
contain the state key — a `head-object` and an `s3 cp`. The key fragment matched both, so the
download returned the empty document meant for the existence probe. The fixture claimed
"apps holds 4 resources" and actually delivered "apps holds 0", the guard correctly allowed
the destroy, and the assertion recorded that correct behaviour as a failure.

So stubs now match on ALL fragments in a list, which forces every stub to name the command it
is standing in for, and `test_fixture_delivers_what_it_claims` pins the fixture itself. A
fixture is code; an unverified one can invert the result of a passing test.
"""

from __future__ import annotations

import importlib.util
import json
import pathlib
import sys

spec = importlib.util.spec_from_file_location(
    "teardown_guard", pathlib.Path(__file__).resolve().parents[1] / "teardown_guard.py"
)
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

PASSED, FAILED = 0, 0


def first(problems: list[str]) -> str:
    """problems[0], or a marker.

    Indexing directly means a mutation that empties the list crashes with IndexError, which
    points at this file instead of at the defect. A test should fail by reporting, not by
    raising.
    """
    return problems[0] if problems else "<no problems reported>"


def check(name: str, got, want) -> None:
    global PASSED, FAILED
    if got == want:
        PASSED += 1
        print(f"  PASS  {name}")
    else:
        FAILED += 1
        print(f"  FAIL  {name}\n          got  {got!r}\n          want {want!r}")


def fake_sh(rules: list[tuple[list[str], tuple[int, str]]]):
    """Replace g.sh.

    Each rule is (fragments, response) and matches only when EVERY fragment appears in the
    joined command. Requiring all of them is what stops one state-key fragment from
    answering both the existence probe and the download.

    An unmatched command returns a loud failure rather than something plausible, so a missing
    stub shows up as an error instead of quietly altering the outcome.
    """

    def _sh(cmd, check=False):
        joined = " ".join(cmd)
        for frags, resp in rules:
            if all(f in joined for f in frags):
                return resp
        return 1, f"UNSTUBBED COMMAND (test bug, not code under test): {joined}"

    return _sh


def svc_json(*types):
    return json.dumps(
        {"items": [{"metadata": {"namespace": "eaf", "name": f"s{i}"}, "spec": {"type": t}}
                   for i, t in enumerate(types)]}
    )


def pvc_json(n):
    return json.dumps(
        {"items": [{"metadata": {"namespace": "memory", "name": f"neo4j-{i}"}, "status": {"phase": "Bound"}}
                   for i in range(n)]}
    )


def state_json(instances_per_resource):
    return json.dumps(
        {"resources": [{"instances": [{} for _ in range(n)]} for n in instances_per_resource]}
    )


EXISTS = (0, "{}")          # head-object success; body is irrelevant to the probe
GONE = (1, "An error occurred (404) when calling the HeadObject operation: Not Found")


def state_rules(layers: dict[str, list[int] | None]):
    """Build stubs for several layers at once.

    `{"apps": [4]}` means the apps state exists and holds one resource with 4 instances.
    `{"apps": None}` means there is no state object for apps.
    """
    rules: list[tuple[list[str], tuple[int, str]]] = []
    for layer, shape in layers.items():
        key = f"workloads/dev/{layer}/terraform.tfstate"
        if shape is None:
            rules.append((["head-object", key], GONE))
            rules.append((["s3 cp", key], GONE))
        else:
            rules.append((["head-object", key], EXISTS))
            rules.append((["s3 cp", key], (0, state_json(shape))))
    return rules


# ───────────────────── the fixture itself, pinned before it is trusted ─────────────────────
print("\nthe fixture — a stub that lies inverts every assertion built on it")

g.sh = fake_sh(state_rules({"apps": [4]}))
check("test_fixture_delivers_what_it_claims: 4 means 4",
      g.state_resource_count("b", "workloads/dev/apps/terraform.tfstate"), 4)

g.sh = fake_sh(state_rules({"apps": None}))
check("test_fixture_delivers_what_it_claims: absent means None",
      g.state_resource_count("b", "workloads/dev/apps/terraform.tfstate"), None)

# An unstubbed command must be loud. Silence here is what let the original bug through.
g.sh = fake_sh([])
try:
    g.state_resource_count("b", "k")
    check("an unstubbed command raises rather than returning something plausible", "no raise", "RuntimeError")
except RuntimeError as e:
    check("an unstubbed command raises rather than returning something plausible",
          "UNSTUBBED" in str(e), True)

# ───────────────────────────── layer ordering ──────────────────────────────
print("\nlayer ordering — a layer may only go once everything above it is gone")

check("platform has cluster-addons and apps above it", g.higher_layers("platform"), ["cluster-addons", "apps"])
check("cluster-addons has only apps above it", g.higher_layers("cluster-addons"), ["apps"])
check("apps is topmost, nothing above", g.higher_layers("apps"), [])
check("registry is not in the teardown order at all", g.higher_layers("registry"), [])
check("registry is absent from LAYER_ORDER", "registry" in g.LAYER_ORDER, False)

# Counting instances, not resource entries.
g.sh = fake_sh(state_rules({"apps": [1, 1, 1]}))
check("three single-instance resources count as 3",
      g.state_resource_count("b", "workloads/dev/apps/terraform.tfstate"), 3)

g.sh = fake_sh(state_rules({"apps": [5]}))
check("one for_each resource with 5 instances counts as 5",
      g.state_resource_count("b", "workloads/dev/apps/terraform.tfstate"), 5)

g.sh = fake_sh(state_rules({"apps": [0, 0]}))
check("emptied shells count as 0, so a destroyed layer does not block",
      g.state_resource_count("b", "workloads/dev/apps/terraform.tfstate"), 0)

# 403 must not be mistaken for absence: that would turn a permissions fault into a pass.
g.sh = fake_sh([(["head-object"], (1, "An error occurred (403) when calling HeadObject: Forbidden"))])
try:
    g.state_resource_count("b", "k")
    check("403 raises rather than passing silently", "no raise", "RuntimeError")
except RuntimeError:
    check("403 raises rather than passing silently", "RuntimeError", "RuntimeError")

# The decisive case: destroying platform while apps still holds resources.
g.sh = fake_sh(state_rules({"cluster-addons": None, "apps": [4]}))
probs = g.check_layer_order("b", "workloads/dev", "platform")
check("REFUSES platform while a layer above holds resources", len(probs), 1)
check("  and names the layer that must go first", "apps" in first(probs), True)
check("  and explains why order matters", "live cluster" in first(probs), True)

# Both above it still present -> two complaints, not one.
g.sh = fake_sh(state_rules({"cluster-addons": [2], "apps": [4]}))
check("REFUSES once per occupied layer above",
      len(g.check_layer_order("b", "workloads/dev", "platform")), 2)

g.sh = fake_sh(state_rules({"cluster-addons": None, "apps": None}))
check("ALLOWS platform when nothing above it exists",
      g.check_layer_order("b", "workloads/dev", "platform"), [])

g.sh = fake_sh(state_rules({"cluster-addons": [0], "apps": [0]}))
check("ALLOWS platform when the layers above are applied but emptied",
      g.check_layer_order("b", "workloads/dev", "platform"), [])

g.sh = fake_sh(state_rules({"apps": [9]}))
check("ALLOWS cluster-addons... no: apps still holds resources, so REFUSES",
      len(g.check_layer_order("b", "workloads/dev", "cluster-addons")), 1)

check("ALLOWS apps unconditionally, it is topmost",
      g.check_layer_order("b", "workloads/dev", "apps"), [])

# ─────────────────────── discovery, so nothing is hardcoded ───────────────────────
print("\ndiscovery — the guard asks the layer what it built rather than being told")


def outputs_rules(layer: str, outputs: dict):
    key = f"workloads/dev/{layer}/terraform.tfstate"
    doc = json.dumps({"resources": [], "outputs": {k: {"value": v} for k, v in outputs.items()}})
    return [(["head-object", key], EXISTS), (["s3 cp", key], (0, doc))]


g.sh = fake_sh(outputs_rules("platform", {
    "cluster_name": "someone-elses-cluster",
    "platform_inventory": {"account_id": "111122223333", "region": "us-east-1"},
}))
found = g.discover("b", "workloads/dev", "platform")
check("discovers the cluster name from state outputs", found.get("cluster"), "someone-elses-cluster")
check("discovers the account id", found.get("account_id"), "111122223333")
check("discovers the region", found.get("region"), "us-east-1")

g.sh = fake_sh(state_rules({"platform": None}))
check("no state means no discovery, not a crash", g.discover("b", "workloads/dev", "platform"), {})

g.sh = fake_sh(outputs_rules("platform", {}))
check("state with no outputs discovers nothing", g.discover("b", "workloads/dev", "platform"), {})

# A cluster_name output that is not a string must not be passed on as one.
g.sh = fake_sh(outputs_rules("platform", {"cluster_name": None}))
check("a null cluster_name is ignored", "cluster" in g.discover("b", "workloads/dev", "platform"), False)

# ──────────────────── Kubernetes objects that own AWS resources ────────────────────
print("\nin-cluster objects — deleting them is the only thing that frees the AWS resource")

ACTIVE = (["describe-cluster"], (0, json.dumps({"cluster": {"status": "ACTIVE"}})))
KUBECFG = (["update-kubeconfig"], (0, ""))
NO_ING = (["get ingress"], (0, json.dumps({"items": []})))
NO_PVC = (["get pvc"], (0, json.dumps({"items": []})))

g.sh = fake_sh([ACTIVE, KUBECFG, (["get svc"], (0, svc_json("ClusterIP", "ClusterIP"))), NO_ING, NO_PVC])
check("clean cluster passes", g.kube_objects_owning_aws("c", "eu-west-2", None), [])

g.sh = fake_sh([ACTIVE, KUBECFG, (["get svc"], (0, svc_json("ClusterIP", "LoadBalancer"))), NO_ING, NO_PVC])
probs = g.kube_objects_owning_aws("c", "eu-west-2", None)
check("REFUSES on a LoadBalancer Service", len(probs), 1)
check("  and names the DependencyViolation consequence", "DependencyViolation" in first(probs), True)
check("  and puts a number on the leak", "19.32" in first(probs), True)

g.sh = fake_sh([ACTIVE, KUBECFG, (["get svc"], (0, svc_json())), NO_ING, (["get pvc"], (0, pvc_json(1)))])
probs = g.kube_objects_owning_aws("c", "eu-west-2", None)
check("REFUSES on a bound PVC", len(probs), 1)
check("  and corrects the reclaimPolicy=Delete misconception",
      "reclaimPolicy=Delete does NOT save you" in first(probs), True)

g.sh = fake_sh([
    ACTIVE, KUBECFG,
    (["get svc"], (0, svc_json("LoadBalancer"))),
    (["get ingress"], (0, json.dumps({"items": [{"metadata": {"namespace": "eaf", "name": "ing"}}]}))),
    (["get pvc"], (0, pvc_json(2))),
])
check("reports all three categories at once", len(g.kube_objects_owning_aws("c", "eu-west-2", None)), 3)

# Re-running a teardown is normal, and must not error.
g.sh = fake_sh([(["describe-cluster"], (1, "An error occurred (ResourceNotFoundException)"))])
check("an absent cluster PASSES — teardown gets re-run", g.kube_objects_owning_aws("c", "eu-west-2", None), [])

g.sh = fake_sh([(["describe-cluster"], (0, json.dumps({"cluster": {"status": "DELETING"}})))])
check("a DELETING cluster passes rather than hanging", g.kube_objects_owning_aws("c", "eu-west-2", None), [])

g.sh = fake_sh([(["describe-cluster"], (1, "AccessDeniedException"))])
check("an unreachable cluster warns but does not block", g.kube_objects_owning_aws("c", "eu-west-2", None), [])

# ───────────── the sweep must not report an all-clear it did not earn ─────────────
print("\nthe sweep — a failed probe must never render as a reassuring zero")

EXPIRED = (1, "An error occurred (ExpiredTokenException) when calling the ListClusters "
              "operation: The security token included in the request is expired")

# The original defect, pinned so it cannot come back: every call failing produced
# "0 clusters, 0 load balancers, 0 volumes" and looked like a clean teardown.
g.sh = fake_sh([([], EXPIRED)])
unknowns = g.sweep("eu-west-2")
check("every probe failing yields unknowns, not zeros", len(unknowns) > 0, True)
check("  and the reason names the expired token", any("Expired" in u for u in unknowns), True)

check("a failed probe is Unknown, not 0",
      isinstance(g.probe(["aws", "eks", "list-clusters"], lambda d: len(d["clusters"])), g.Unknown), True)

g.sh = fake_sh([(["list-clusters"], (0, json.dumps({"clusters": ["a", "b"]})))])
check("a successful probe returns the real count",
      g.probe(["aws", "eks", "list-clusters"], lambda d: len(d["clusters"])), 2)

g.sh = fake_sh([(["list-clusters"], (0, "not json at all"))])
check("an unparseable response is Unknown, not 0",
      isinstance(g.probe(["aws", "eks", "list-clusters"], lambda d: len(d["clusters"])), g.Unknown), True)

g.sh = fake_sh([(["list-clusters"], (0, json.dumps({"wrong_key": []})))])
check("a response missing the expected key is Unknown, not 0",
      isinstance(g.probe(["aws", "eks", "list-clusters"], lambda d: len(d["clusters"])), g.Unknown), True)

# A genuinely empty account must still read as a clean zero, or the fix would make the
# tool useless by crying wolf.
ALL_EMPTY = [
    (["list-clusters"], (0, json.dumps({"clusters": []}))),
    (["describe-instances"], (0, json.dumps({"Reservations": []}))),
    (["describe-nat-gateways"], (0, json.dumps({"NatGateways": []}))),
    (["elbv2", "describe-load-balancers"], (0, json.dumps({"LoadBalancers": []}))),
    (["elb", "describe-load-balancers"], (0, json.dumps({"LoadBalancerDescriptions": []}))),
    (["describe-volumes"], (0, json.dumps({"Volumes": []}))),
    (["describe-addresses"], (0, json.dumps({"Addresses": []}))),
    (["describe-snapshots"], (0, json.dumps({"Snapshots": []}))),
]
g.sh = fake_sh(ALL_EMPTY)
check("a genuinely empty region reports no unknowns", g.sweep("eu-west-2"), [])

# One failed probe among successes must not be absorbed by the others.
g.sh = fake_sh([(["elbv2", "describe-load-balancers"], EXPIRED)] + ALL_EMPTY)
check("one failed probe among successes is still reported", len(g.sweep("eu-west-2")), 1)

# Half of the load-balancer answer failing makes the total unknown, never a partial count.
g.sh = fake_sh([(["elb", "describe-load-balancers"], EXPIRED)] + ALL_EMPTY)
check("a partial load-balancer answer is not presented as a total", len(g.sweep("eu-west-2")), 1)

print(f"\n  {PASSED} passed, {FAILED} failed")
sys.exit(1 if FAILED else 0)
