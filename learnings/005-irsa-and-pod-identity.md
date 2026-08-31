# 005 — IRSA and Pod Identity

*Written 2026-08-31. Applies to EKS 1.36. Add-on Pod Identity recommendations were
queried from the live EKS API in `eu-west-2` on 2026-08-31.*

## The question

> Can u tell me this what is this irsa, I understand the concepts but one thing which
> I am not able to visualise is that.

## Short answer

IRSA is how a **pod** gets AWS credentials without being handed a key. The pod is
given a short-lived signed token proving "I am service account X in cluster Y", it
trades that token to AWS STS, and STS hands back credentials for an IAM role.

**Pod Identity** is the newer way to do the same job. Same goal, different plumbing:
instead of the pod proving itself to STS with a token AWS has to verify against your
cluster, an agent on the node asks the EKS API "who is this service account allowed
to be?" and EKS answers.

## Start with the problem, not the acronym

A pod wants to call `bedrock:InvokeModel`. AWS requires every API call to be signed
with credentials. So where do the pod's credentials come from?

```
   ┌───────────────────────────────────────────────────────────┐
   │  EC2 node                                                 │
   │                                                           │
   │   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐     │
   │   │  agent pod  │   │  neo4j pod  │   │ firecrawl   │     │
   │   │             │   │             │   │    pod      │     │
   │   │  needs      │   │  needs      │   │  needs      │     │
   │   │  bedrock    │   │  nothing    │   │  nothing    │     │
   │   └─────────────┘   └─────────────┘   └─────────────┘     │
   │                                                           │
   │   ────────────────── node IAM role ──────────────────     │
   │        eaf-dev-node-role  (the instance profile)          │
   └───────────────────────────────────────────────────────────┘
```

**The naive answer is the node role, and it is the wrong answer.** Every pod on the
node can reach the instance metadata service, so every pod gets the node's
credentials. Put `bedrock:InvokeModel` on the node role and Neo4j has it too. Put
`s3:*` there and a compromised Firecrawl browser has it.

The node role should carry only what the *kubelet itself* needs — register with the
cluster, pull images. Anything a workload needs has to be scoped to that workload.

That is the problem both IRSA and Pod Identity solve: **per-pod identity, on a node
whose own identity is shared.**

## IRSA, drawn

The mechanism is OIDC federation. Your cluster acts as an identity provider, and IAM
is configured to trust it.

```
  SETUP, once per cluster
  ═══════════════════════

   ┌────────────────────────────┐        ┌──────────────────────────────┐
   │  EKS cluster               │        │  IAM                         │
   │                            │        │                              │
   │  publishes a public URL:   │───────▶│  OIDC identity provider      │
   │  oidc.eks.eu-west-2        │ you    │  registered for that URL     │
   │    .amazonaws.com/id/ABC12 │ create │  (holds its public keys)     │
   │                            │  this  │                              │
   │  (the "OIDC issuer")       │        │                              │
   └────────────────────────────┘        └──────────────────────────────┘


  AT RUNTIME, every time a pod needs credentials
  ══════════════════════════════════════════════

   ┌─────────────────────────────────────────────────────────────────────┐
   │  pod                                                                │
   │                                                                     │
   │   serviceAccountName: eaf-agent                                     │
   │                                                                     │
   │   /var/run/secrets/eks.amazonaws.com/serviceaccount/token           │
   │   ▲                                                                 │
   │   │  ① kubelet writes a signed JWT here and rotates it              │
   │   │     payload says:                                               │
   │   │       iss: oidc.eks.eu-west-2.amazonaws.com/id/ABC12            │
   │   │       sub: system:serviceaccount:eaf:eaf-agent                  │
   │   │       aud: sts.amazonaws.com                                    │
   └───┼─────────────────────────────────────────────────────────────────┘
       │
       │  ② AWS SDK reads the token, calls
       │     sts:AssumeRoleWithWebIdentity
       ▼
   ┌─────────────────────────────────────────────────────────────────────┐
   │  AWS STS                                                            │
   │                                                                     │
   │   ③ fetches the cluster's public keys from that issuer URL          │
   │   ④ verifies the JWT signature — proves the cluster minted it       │
   │   ⑤ checks the role's TRUST POLICY:                                 │
   │                                                                     │
   │        Federated: <the OIDC provider ARN>                           │
   │        oidc.eks.eu-west-2.amazonaws.com/id/ABC12:sub                │
   │            == system:serviceaccount:eaf:eaf-agent                   │
   │        oidc.eks.eu-west-2.amazonaws.com/id/ABC12:aud                │
   │            == sts.amazonaws.com                                     │
   └─────────────────────────────────────────────────────────────────────┘
       │
       │  ⑥ temporary credentials, ~1 hour
       ▼
     pod calls bedrock:InvokeModel
```

The thing to hold onto: **the role's trust policy names your specific cluster's issuer
URL.** That URL contains a cluster-unique id. This is `modules/iam-role`'s `eks_irsa`
trust type, and it is why that module needs `oidc_provider_arn`.

## Pod Identity, drawn

Same problem, and the pod-side story is nearly identical. What changes is who does
the verifying.

```
  SETUP
  ═════

   ┌────────────────────────────┐        ┌──────────────────────────────┐
   │  eks-pod-identity-agent    │        │  IAM role                    │
   │  add-on (a DaemonSet)      │        │                              │
   │  runs on every node        │        │  trust policy:               │
   └────────────────────────────┘        │    Service: pods.eks         │
                                         │      .amazonaws.com          │
   ┌────────────────────────────┐        │    Action: sts:AssumeRole    │
   │  Pod Identity Association  │        │            sts:TagSession    │
   │  registered in the EKS API:│        │                              │
   │                            │        │  ← NO cluster id anywhere    │
   │   cluster + namespace +    │        │                              │
   │   serviceaccount → role    │        └──────────────────────────────┘
   └────────────────────────────┘


  AT RUNTIME
  ══════════

   ┌─────────────────────────────────────────────────────────────────────┐
   │  pod  ·  serviceAccountName: eaf-agent                              │
   └──────────────────────────┬──────────────────────────────────────────┘
                              │  ① SDK finds credentials via env vars
                              │     EKS sets, pointing at the local agent
                              ▼
   ┌─────────────────────────────────────────────────────────────────────┐
   │  pod-identity-agent on this node                                    │
   │                              │                                      │
   │                              │  ② asks the EKS Auth API:            │
   │                              │     "namespace eaf, SA eaf-agent —   │
   │                              │      which role?"                    │
   └──────────────────────────────┼──────────────────────────────────────┘
                                  ▼
   ┌─────────────────────────────────────────────────────────────────────┐
   │  EKS Auth API                                                       │
   │   ③ looks up the association, assumes the role, returns creds       │
   └─────────────────────────────────────────────────────────────────────┘
```

## The difference that actually matters

Both give per-pod credentials. Both use short-lived tokens. Neither involves a stored
key. The real divergence is **where the cluster→role mapping lives.**

```
  IRSA                                   POD IDENTITY
  ────────────────────────────────────   ────────────────────────────────────
  The mapping lives in                   The mapping lives in
  the ROLE'S TRUST POLICY.               the EKS API, as an association.

    trust:                                 trust:
      oidc.eks.../id/ABC12:sub               Service: pods.eks.amazonaws.com
        = system:serviceaccount:eaf:x
                                           association (separate object):
      ▲                                      cluster=eaf-dev
      └── cluster-specific                   namespace=eaf, sa=x → role
                                                   ▲
                                                   └── cluster named here instead

  Rebuild the cluster → new issuer id    Rebuild the cluster → recreate the
  → EVERY trust policy is now stale      associations. Roles untouched.

  Needs: an IAM OIDC provider per        Needs: the eks-pod-identity-agent
  cluster (limit 100 per account)        add-on, installed BEFORE nodes join

  Role is reusable across clusters?      Role is reusable across clusters?
  No — trust names one issuer            Yes — trust names a service principal
```

## Why it matters in this repository

**The add-ons need this, and AWS now tells you what to use.** Queried live on
2026-08-31, `describe-addon-configuration` returns a Pod Identity recommendation for
exactly the two add-ons that need AWS permissions:

| Add-on | Service account | Recommended policy |
|---|---|---|
| `vpc-cni` | `aws-node` | `AmazonEKS_CNI_Policy` |
| `aws-ebs-csi-driver` | `ebs-csi-controller-sa` | `AmazonEBSCSIDriverPolicyV2` |

`coredns` and `kube-proxy` return nothing, because they need no AWS permissions at
all. Useful to know — it means two fewer roles than the design implied.

**Why the CNI needs a role at all.** `aws-node` creates elastic network interfaces
and assigns VPC IPs. Those are EC2 API calls. Historically `AmazonEKS_CNI_Policy` was
attached to the *node role*, which meant every pod on the node inherited the ability
to manipulate network interfaces. Moving it to a pod-scoped identity is the fix, and
it is why the design takes that policy off the node role.

**One ordering constraint.** With Pod Identity, `eks-pod-identity-agent` has to be
installed before the node group, alongside `vpc-cni` and `kube-proxy`. Nodes that
join before the CNI is present fail with `NodeCreationFailure: NetworkPluginNotReady`
and stay `NotReady`.

## What AWS actually says — the best-practice answer

*Asked directly: "what is the best practice, IRSA or Pod Identity? can u confirm with
aws?" Confirmed 2026-08-31 from the source of AWS's EKS Best Practices Guide
(`github.com/aws/aws-eks-best-practices`, branch `mainline`), not from blogs.*

**AWS recommends Pod Identity.** Two statements, both from the Best Practices Guide:

> Unless you have specific usecases for IRSA, we recommend you use EKS Pod Identities
> when using EKS.

— `latest/bpg/security/iam.adoc`, section *EKS Pod Identities compared to IRSA*

> EKS Pod Identities are the recommended approach for new workloads on supported node
> types, while IRSA remains a fully supported alternative.

— `latest/bpg/security/multiaccount.adoc`

Two things to note about that wording. It is **scoped to "supported node types"**, and
it calls IRSA **"a fully supported alternative"** — not legacy, not deprecated, with no
end-of-support date. In AWS's docs the word *legacy* is attached to the `aws-auth`
ConfigMap, which is a different subject entirely.

### AWS's own comparison

From `iam.adoc`:

| | Pod Identity | IRSA |
|---|---|---|
| Needs permission to create an OIDC IdP in your account | No | Yes |
| Needs a unique IdP per cluster | No | Yes |
| Sets session tags for ABAC | Yes | No |
| Needs an `iam:PassRole` check | **Yes** | No |
| Consumes your account's STS quota | No | Yes |
| Cross-account access | Indirect, via role chaining | Direct, via `sts:AssumeRoleWithWebIdentity` |
| Needs the Pod Identity Agent DaemonSet | Yes | No |

### Where IRSA is still the right answer

Pod Identity is **not available** for:

- Pods on **AWS Fargate** — Linux or Windows
- Pods on **Windows** EC2 instances
- **AWS Outposts**, **EKS Anywhere**, or self-managed Kubernetes on EC2 — it is an EKS-only feature

And IRSA remains preferable when you need **direct cross-account** role assumption, or
when you would exceed **5,000 Pod Identity associations per cluster** (a documented
limit).

### Cross-account access is built in, despite what the comparison table implies

*Follow-up question: "in future we might need cross account access for models? then how
do we do?"*

AWS's comparison table says Pod Identity reaches another account "indirectly with role
chaining", which reads like a limitation. It is not — **EKS performs the chaining for
you**, and it is a documented parameter, not a workaround.

An association takes two roles:

```
  ┌─── cluster account (EAF-DEV) ────┐   ┌─── target account ──────────────┐
  │                                  │   │                                 │
  │  pod  ·  serviceAccount: agent   │   │  Role B                         │
  │            │                     │   │    trust: Role A                │
  │            ▼                     │   │      + Condition on             │
  │  association:                    │   │        sts:ExternalId           │
  │    role_arn        = Role A ─────┼───┼──▶   permits bedrock:Invoke*     │
  │    target_role_arn = Role B      │   │                                 │
  └──────────────────────────────────┘   └─────────────────────────────────┘

  EKS assumes Role A, then uses those credentials to assume Role B,
  and injects Role B's credentials into the pod.
```

From the API reference for `CreatePodIdentityAssociation`:

> With a target role, EKS Pod Identity automatically performs two role assumptions in
> sequence: first assuming the role in the association that is in this account, then
> using those credentials to assume the target IAM role.

Terraform supports this today: `aws_eks_pod_identity_association` has `target_role_arn`,
and **exports a computed `external_id`** to put in the target role's trust policy as an
`sts:ExternalId` condition. That is a confused-deputy guard, and it is handed to you
rather than invented.

**Application code does not change.** No `assume_role` call, no credential handling.
The pod uses the default credential chain and receives the target role's credentials.

So cross-account is not a reason to choose IRSA. The difference is one hop versus two,
and the second hop is EKS's job.

#### A related feature worth knowing

The same association accepts an optional inline `policy` — a session policy whose
effective permissions are the *intersection* of it and the role's policies. One shared
role can therefore serve several service accounts, each narrowed differently, instead of
minting a role per workload. Directly relevant to the goal of not accumulating roles
nobody can account for.

Two constraints: it requires `disable_session_tags = true`, and when combined with
`target_role_arn` it restricts only the *target* role's permissions.

#### Two caveats before building this

**Bedrock is regional and normally invoked in-account.** Cross-account model access is a
real pattern but not the default one — it usually means a central account holding
provisioned throughput, or a shared gateway. Worth being explicit about the goal first.

**The guardrail SCP currently denies `inference-profile/*`.** That already rules out
`anthropic.claude-haiku-4-5`, which is inference-profile-only, and it will block
cross-region inference too. That is an SCP change, independent of Pod Identity.

### Which applies to this repository

Nodes here are **Linux EC2 instances in a managed node group**, which is exactly the
supported case. None of the IRSA-only conditions apply: single account per environment,
no Fargate, no Windows, no EKS Anywhere, and nowhere near 5,000 associations.

So the recommendation applies cleanly. Two consequences worth carrying forward:

- **`iam:PassRole` is required.** Whichever role creates a Pod Identity association
  needs `iam:PassRole` on the target role. `modules/iam-role` already has a scoped
  `pass_role` feature, so this is a matter of using it rather than building it.
- **Associations are eventually consistent.** AWS warns of delays of several seconds
  after the API call, and advises against creating them in high-availability code
  paths. For Terraform this is an ordering concern at apply time, not a runtime one.

### A correction to something I said earlier

When recommending Pod Identity I leaned on "roles survive cluster rebuilds". That is
true, but I oversold its relevance: **the current build is from an empty account, so
for this rebuild it makes no difference at all.** The argument only pays off the
*next* time a cluster is replaced.

I also called it "both are fine, one is simpler — not a correctness call." That was
too weak. Having since checked the Best Practices Guide at source, AWS states a
recommendation, and this cluster sits inside its stated scope. The stronger and more
accurate reasons are the ones above: AWS recommends it, no per-cluster OIDC provider is
needed, no STS quota is consumed, and it removes the
`com.amazonaws.eu-west-2.oidc-eks` VPC endpoint the design otherwise requires once the
cluster endpoint goes private.

IRSA is still not deprecated, and for Fargate, Windows nodes, or direct cross-account
access it remains the correct choice.

## Sources

- [IAM roles for service accounts](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html) — IRSA mechanism
- [Configure Amazon VPC CNI plugin to use IRSA](https://docs.aws.amazon.com/eks/latest/userguide/cni-iam-role.html)
- [Understand how EKS Pod Identity works](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-how-it-works.html)
- [Set up the Amazon EKS Pod Identity Agent](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html)
- [IAM roles for Amazon EKS add-ons](https://docs.aws.amazon.com/en_us/eks/latest/userguide/add-ons-iam.html) — add-ons can manage their own associations
- [Use Pod Identities to assign an IAM role to an add-on](https://docs.aws.amazon.com/eks/latest/userguide/update-addon-role.html)
- [Grant Kubernetes workloads access to AWS using Kubernetes Service Accounts](https://docs.aws.amazon.com/eks/latest/userguide/service-accounts.html) — AWS's side-by-side comparison, including the OIDC provider and trust-policy-size limits
- [Learn how EKS Pod Identity grants pods access to AWS services](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html) — restrictions, the 5,000-association limit, eventual consistency
- AWS EKS Best Practices Guide, source repository [`aws/aws-eks-best-practices`](https://github.com/aws/aws-eks-best-practices) branch `mainline`, read 2026-08-31: `latest/bpg/security/iam.adoc` and `latest/bpg/security/multiaccount.adoc`. Read from the repository because the rendered docs pages did not return extractable content
- Live API, `eu-west-2`, 2026-08-31: `aws eks describe-addon-configuration --addon-name vpc-cni|aws-ebs-csi-driver|coredns|kube-proxy`

*Content from AWS documentation was rephrased for compliance with licensing
restrictions.*
