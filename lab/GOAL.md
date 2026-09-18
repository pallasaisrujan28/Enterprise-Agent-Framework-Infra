# What `lab/` is for

Experimenting with **self-reviving memory, skills, subagent architectures and reinforcement
learning**. The infrastructure exists to get out of the way.

## In scope

A cluster and the services an agent needs, applied and destroyed from a terminal:

```bash
source .local/dev-env.sh
cd lab/cluster && terraform apply     # once, ~15 min
cd ../apps     && terraform apply     # ~2 min
```

## Deliberately out of scope

The pipeline and the accounts. Not because they are wrong — they work — but because none of
them move the experiment forward:

dispatched workflows · OIDC trust policies · permissions boundaries · approval gates · plan
artefacts · SCPs · GuardDuty · IAM inventories · lock-file enforcement · NetworkPolicy ·
capacity preconditions

## The design document is historical

`.kiro/specs/eks-platform-restructure/design.md` describes a different goal: a reviewed,
gated, multi-account platform, with twelve steps and nineteen numbered correctness properties.
That work is real and it is done. It is also **not what `lab/` answers to.**

This matters because that document is long, confident, and the only thing in the repository
that states an intent — so anyone reading it, including a fresh agent session, will start
optimising the pipeline again. That has already happened more than once.

**`lab/` is not held to those properties.** Public endpoints, local state, no approval gate and
no permissions boundary are correct here. Do not "fix" them.

## Two habits worth keeping

Everything else was dropped for speed. These two cost seconds and have each already cost
hours:

**Check the account before trusting credentials.** One credential paste in this project was
for a different member account in the same organisation. It authenticates fine and operates on
the wrong account — a successful command that touches nothing you meant to touch.

```bash
aws sts get-caller-identity --query Account --output text   # expect 718438899462
```

**Verify against the live API, not against your own comments.** Two confident comments in
`lab/cluster/main.tf` were exactly backwards and both were found by applying:

- the SSO role ARN needs its `/aws-reserved/sso.amazonaws.com/` path; stripping it produces
  `invalid principal`
- the EBS CSI controller cannot use the node role, because it is an ordinary pod and the node
  group sets an IMDS hop limit of 1. It needs Pod Identity, and without it the add-on hangs in
  `CREATING` while the controller sits at 1/6 containers

A comment describing how an API behaves is a hypothesis until something applies it.

## Cost

About **$0.62/hour** with the cluster up. `terraform destroy` in `apps` then `cluster` takes it
to roughly zero. `make teardown-check` confirms nothing was left billing — it queries AWS
directly rather than reading state, so it does not care which module created what.
