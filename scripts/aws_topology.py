#!/usr/bin/env python3
"""Draw the live AWS topology as a Mermaid diagram.

Reads the account through the AWS API and emits Mermaid, which renders natively in
VS Code and on GitHub — so the picture lives in the repository and needs no plugin,
no Graphviz, and no separate rendering step.

WHY THIS READS AWS RATHER THAN TERRAFORM STATE. A diagram generated from state or
from configuration shows what *should* exist. This one shows what *does*. Those
differ exactly when it matters, and the whole point of asking for a picture is to
see the second kind.

It also means the diagram works for anything in the account, including resources
this repository does not own — which is how an orphan becomes visible.

Read-only throughout: every call is a describe or a list. Nothing here can change
the account.

    python3 scripts/aws_topology.py                     # to stdout
    python3 scripts/aws_topology.py -o docs/topology.md # to a file
    python3 scripts/aws_topology.py --region eu-west-2 --vpc vpc-0abc...

Requires credentials for the account you want to draw. Nothing is hardcoded to any
account, region, or cluster.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


class AwsError(RuntimeError):
    pass


def aws(*args: str, region: str | None = None) -> object:
    """Run one read-only AWS CLI call and return parsed JSON."""
    cmd = ["aws", *args, "--output", "json"]
    if region:
        cmd += ["--region", region]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise AwsError(f"{' '.join(args)}\n{proc.stderr.strip()}")
    out = proc.stdout.strip()
    return json.loads(out) if out else None


def name_of(tags: list[dict] | None) -> str:
    for t in tags or []:
        if t.get("Key") == "Name":
            return t["Value"]
    return ""


def tag(tags: list[dict] | None, key: str) -> str:
    for t in tags or []:
        if t.get("Key") == key:
            return t["Value"]
    return ""


def node_id(prefix: str, raw: str) -> str:
    """Mermaid ids cannot contain hyphens or dots in all renderers."""
    return prefix + "_" + "".join(c if c.isalnum() else "_" for c in raw)


# ── Collection ────────────────────────────────────────────────────────────────


def collect(region: str, vpc_id: str | None) -> dict:
    ident = aws("sts", "get-caller-identity")
    account = ident["Account"]

    vpcs = aws("ec2", "describe-vpcs", "--filters", "Name=isDefault,Values=false", region=region)["Vpcs"]
    if vpc_id:
        vpcs = [v for v in vpcs if v["VpcId"] == vpc_id]
    if not vpcs:
        raise AwsError(f"no non-default VPC found in {region}. Nothing to draw.")

    vpc = vpcs[0]
    vid = vpc["VpcId"]

    subnets = aws("ec2", "describe-subnets", "--filters", f"Name=vpc-id,Values={vid}", region=region)["Subnets"]
    igws = aws("ec2", "describe-internet-gateways", "--filters", f"Name=attachment.vpc-id,Values={vid}", region=region)["InternetGateways"]
    nats = aws("ec2", "describe-nat-gateways", "--filter", f"Name=vpc-id,Values={vid}", region=region)["NatGateways"]
    rtbs = aws("ec2", "describe-route-tables", "--filters", f"Name=vpc-id,Values={vid}", region=region)["RouteTables"]
    enis = aws("ec2", "describe-network-interfaces", "--filters", f"Name=vpc-id,Values={vid}", region=region)["NetworkInterfaces"]

    instances = [
        i
        for r in aws("ec2", "describe-instances", "--filters",
                     f"Name=vpc-id,Values={vid}", "Name=instance-state-name,Values=running",
                     region=region)["Reservations"]
        for i in r["Instances"]
    ]

    clusters = []
    for cname in aws("eks", "list-clusters", region=region)["clusters"]:
        c = aws("eks", "describe-cluster", "--name", cname, region=region)["cluster"]
        if c["resourcesVpcConfig"]["vpcId"] != vid:
            continue

        addons = []
        for aname in aws("eks", "list-addons", "--cluster-name", cname, region=region)["addons"]:
            a = aws("eks", "describe-addon", "--cluster-name", cname, "--addon-name", aname, region=region)["addon"]
            addons.append(a)

        groups = []
        for gname in aws("eks", "list-nodegroups", "--cluster-name", cname, region=region)["nodegroups"]:
            groups.append(aws("eks", "describe-nodegroup", "--cluster-name", cname, "--nodegroup-name", gname, region=region)["nodegroup"])

        entries = []
        for parn in aws("eks", "list-access-entries", "--cluster-name", cname, region=region)["accessEntries"]:
            pol = aws("eks", "list-associated-access-policies", "--cluster-name", cname,
                      "--principal-arn", parn, region=region)["associatedAccessPolicies"]
            entries.append({"principal": parn, "policies": pol})

        # The list call returns ids and the owning resource but NOT the role, so each
        # one needs a describe. Worth the extra calls: the role is the whole point, and
        # ownerArn distinguishes an association an add-on manages for itself from one
        # somebody created by hand.
        assocs = []
        for summary in aws("eks", "list-pod-identity-associations", "--cluster-name", cname,
                           region=region).get("associations", []):
            full = aws("eks", "describe-pod-identity-association", "--cluster-name", cname,
                       "--association-id", summary["associationId"], region=region)["association"]
            assocs.append(full)

        clusters.append({"cluster": c, "addons": addons, "nodegroups": groups,
                         "access": entries, "pod_identity": assocs})

    return {"account": account, "region": region, "vpc": vpc, "subnets": subnets,
            "igws": igws, "nats": nats, "rtbs": rtbs, "enis": enis,
            "instances": instances, "clusters": clusters}


# ── Rendering ─────────────────────────────────────────────────────────────────


def render(d: dict) -> str:
    L: list[str] = []
    vpc, region, account = d["vpc"], d["region"], d["account"]
    vid = vpc["VpcId"]

    L.append(f"# Live AWS topology — `{account}` / `{region}`")
    L.append("")
    L.append("*Generated by `make topology`. Read from the AWS API, so this is what exists,")
    L.append("not what the configuration intends. Regenerate rather than edit.*")
    L.append("")

    # ── Network ───────────────────────────────────────────────────────────────
    L.append("## Network")
    L.append("")
    L.append("```mermaid")
    L.append("graph TB")
    L.append("  internet([Internet])")

    igw_ids = [g["InternetGatewayId"] for g in d["igws"]]
    for g in igw_ids:
        L.append(f'  {node_id("igw", g)}["IGW<br/>{g}"]')

    public = [s for s in d["subnets"] if s.get("MapPublicIpOnLaunch")]
    private = [s for s in d["subnets"] if not s.get("MapPublicIpOnLaunch")]
    azs = sorted({s["AvailabilityZone"] for s in d["subnets"]})

    # Which subnet each NAT lives in, and its public address.
    nat_by_subnet: dict[str, dict] = {}
    for n in d["nats"]:
        if n["State"] != "available":
            continue
        addr = (n.get("NatGatewayAddresses") or [{}])[0]
        nat_by_subnet[n["SubnetId"]] = {"id": n["NatGatewayId"], "ip": addr.get("PublicIp", "?")}

    instances_by_subnet: dict[str, list[dict]] = {}
    for i in d["instances"]:
        instances_by_subnet.setdefault(i.get("SubnetId", ""), []).append(i)

    for az in azs:
        L.append(f'  subgraph AZ_{az.replace("-", "_")}["{az}"]')
        for s in [x for x in public if x["AvailabilityZone"] == az]:
            sid = s["SubnetId"]
            L.append(f'    {node_id("sn", sid)}["public {s["CidrBlock"]}<br/>{sid}"]')
            if sid in nat_by_subnet:
                n = nat_by_subnet[sid]
                L.append(f'    {node_id("nat", n["id"])}["NAT<br/>{n["ip"]}"]')
        for s in [x for x in private if x["AvailabilityZone"] == az]:
            sid = s["SubnetId"]
            free = s.get("AvailableIpAddressCount", "?")
            L.append(f'    {node_id("sn", sid)}["private {s["CidrBlock"]}<br/>{free} IPs free"]')
            for i in instances_by_subnet.get(sid, []):
                L.append(f'    {node_id("ec2", i["InstanceId"])}(["{i["InstanceType"]}<br/>{i.get("PrivateIpAddress", "?")}"])')
        L.append("  end")

    for g in igw_ids:
        L.append(f'  internet <--> {node_id("igw", g)}')
    for s in public:
        for g in igw_ids:
            L.append(f'  {node_id("igw", g)} --- {node_id("sn", s["SubnetId"])}')
    for sid, n in nat_by_subnet.items():
        L.append(f'  {node_id("nat", n["id"])} --> {node_id("sn", sid)}')

    # Private subnets route egress through whichever NAT their route table names.
    for rtb in d["rtbs"]:
        nat_targets = [r.get("NatGatewayId") for r in rtb.get("Routes", []) if r.get("NatGatewayId")]
        if not nat_targets:
            continue
        for assoc in rtb.get("Associations", []):
            sid = assoc.get("SubnetId")
            if not sid:
                continue
            for nid in nat_targets:
                L.append(f'  {node_id("sn", sid)} -.->|egress| {node_id("nat", nid)}')

    for i in d["instances"]:
        if i.get("SubnetId"):
            L.append(f'  {node_id("sn", i["SubnetId"])} --- {node_id("ec2", i["InstanceId"])}')

    L.append("```")
    L.append("")

    # ── Cluster ───────────────────────────────────────────────────────────────
    for c in d["clusters"]:
        cl = c["cluster"]
        cname = cl["name"]
        L.append(f"## EKS cluster `{cname}`")
        L.append("")
        L.append("| | |")
        L.append("|---|---|")
        L.append(f'| status | `{cl["status"]}` |')
        L.append(f'| version | `{cl["version"]}` (platform `{cl["platformVersion"]}`) |')
        L.append(f'| authentication | `{cl.get("accessConfig", {}).get("authenticationMode", "?")}` |')
        pub = cl["resourcesVpcConfig"]["endpointPublicAccess"]
        cidrs = ", ".join(cl["resourcesVpcConfig"].get("publicAccessCidrs") or []) or "-"
        L.append(f'| endpoint | public={pub} private={cl["resourcesVpcConfig"]["endpointPrivateAccess"]} |')
        L.append(f"| public CIDRs | `{cidrs}` |")
        L.append(f'| support | `{cl.get("upgradePolicy", {}).get("supportType", "?")}` |')
        L.append("")

        L.append("```mermaid")
        L.append("graph LR")
        L.append(f'  cp["control plane<br/>{cname}<br/>{cl["version"]}"]')

        L.append('  subgraph addons["add-ons"]')
        for a in c["addons"]:
            pd = a.get("podIdentityAssociations") or []
            ident = "pod identity" if pd else "no IAM"
            L.append(f'    {node_id("ad", a["addonName"])}["{a["addonName"]}<br/>{a["addonVersion"]}<br/>{a["status"]} · {ident}"]')
        L.append("  end")

        L.append('  subgraph pools["node groups"]')
        for g in c["nodegroups"]:
            sc = g["scalingConfig"]
            L.append(f'    {node_id("ng", g["nodegroupName"])}["{g["nodegroupName"]}<br/>{g["instanceTypes"][0]} x{sc["desiredSize"]}'
                     f'<br/>{g["status"]} · min {sc["minSize"]} max {sc["maxSize"]}"]')
        L.append("  end")

        L.append("  cp --- addons")
        L.append("  cp --- pools")
        L.append("```")
        L.append("")

        # Who can reach the API, and with what.
        L.append("### Who can reach the Kubernetes API")
        L.append("")
        L.append("| Principal | Policies | Scope |")
        L.append("|---|---|---|")
        for e in sorted(c["access"], key=lambda x: x["principal"]):
            short = e["principal"].split("/")[-1]
            if not e["policies"]:
                L.append(f"| `{short}` | *none* | — |")
            for p in e["policies"]:
                pol = p["policyArn"].split("/")[-1]
                scope = p["accessScope"]["type"]
                ns = ", ".join(p["accessScope"].get("namespaces") or [])
                L.append(f'| `{short}` | `{pol}` | {scope}{" (" + ns + ")" if ns else ""} |')
        L.append("")
        L.append("*Entries with no policies are registered but hold no permissions. EKS creates")
        L.append("some automatically — the node role and the cluster's own service-linked role.*")
        L.append("")

        if c["pod_identity"]:
            L.append("### Pod Identity — which service account gets which role")
            L.append("")
            L.append("| Namespace | Service account | Role | Managed by |")
            L.append("|---|---|---|---|")
            for a in sorted(c["pod_identity"], key=lambda x: (x["namespace"], x["serviceAccount"])):
                role = a.get("roleArn", "?").split("/")[-1]
                owner = a.get("ownerArn")
                who = f'add-on `{owner.split("/")[-2]}`' if owner else "this layer directly"
                L.append(f'| `{a["namespace"]}` | `{a["serviceAccount"]}` | `{role}` | {who} |')
            L.append("")
            L.append("*An association owned by an add-on is one the add-on maintains for itself, which")
            L.append("is what `pod_identity_association` on `aws_eks_addon` produces. Anything showing")
            L.append("as unmanaged was created outside this layer.*")
            L.append("")

    # ── Pod IP budget ─────────────────────────────────────────────────────────
    prefixed = [n for n in d["enis"] if n.get("Ipv4Prefixes")]
    L.append("## Pod IP allocation")
    L.append("")
    if prefixed:
        total = sum(len(n["Ipv4Prefixes"]) for n in prefixed)
        L.append(f"**Prefix delegation is active.** {len(prefixed)} network interfaces carry "
                 f"{total} `/28` prefixes between them, rather than individual secondary addresses.")
        L.append("")
        L.append("| ENI | Prefixes | Pod IPs from prefixes |")
        L.append("|---|---|---|")
        for n in sorted(prefixed, key=lambda x: x["NetworkInterfaceId"]):
            pfx = [p["Ipv4Prefix"] for p in n["Ipv4Prefixes"]]
            L.append(f'| `{n["NetworkInterfaceId"]}` | {", ".join(f"`{p}`" for p in pfx)} | {len(pfx) * 16} |')
        L.append("")
        L.append("*Each `/28` is 16 addresses. Without prefix delegation the CNI assigns secondary")
        L.append("IPs one at a time and the per-node pod ceiling is far lower — which is a limit on")
        L.append("pod count reached long before CPU or memory runs out.*")
    else:
        L.append("**No prefix delegation detected.** Network interfaces carry individual secondary")
        L.append("addresses, so the per-node pod ceiling is the ENI secondary-IP limit. Note this")
        L.append("cannot be changed on running nodes — enabling it requires replacing them.")
    L.append("")

    return "\n".join(L) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description="Draw the live AWS topology as Mermaid.")
    ap.add_argument("--region", default=None, help="AWS region. Defaults to the CLI's configured region.")
    ap.add_argument("--vpc", default=None, help="VPC id. Defaults to the first non-default VPC found.")
    ap.add_argument("-o", "--output", default=None, help="Write here instead of stdout.")
    args = ap.parse_args()

    # Env vars first, because `aws configure get region` reads the config FILE and
    # ignores AWS_REGION and AWS_DEFAULT_REGION. Resolving in the wrong order gives an
    # empty region, and the resulting calls fail with an authorization error rather
    # than a missing-region one — which sends you looking at IAM instead of at this.
    region = (
        args.region
        or os.environ.get("AWS_REGION")
        or os.environ.get("AWS_DEFAULT_REGION")
        or subprocess.run(["aws", "configure", "get", "region"],
                          capture_output=True, text=True).stdout.strip()
        or None
    )
    if not region:
        print("no region: pass --region, or set AWS_REGION / AWS_DEFAULT_REGION", file=sys.stderr)
        return 2

    try:
        doc = render(collect(region, args.vpc))
    except AwsError as e:
        print(f"aws call failed:\n{e}", file=sys.stderr)
        return 1

    if args.output:
        p = Path(args.output)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(doc)
        print(f"wrote {p}", file=sys.stderr)
    else:
        sys.stdout.write(doc)
    return 0


if __name__ == "__main__":
    sys.exit(main())
