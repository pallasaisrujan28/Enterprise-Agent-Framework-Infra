# Enterprise Agent Framework — Infrastructure

Terraform for the AWS accounts and guardrails the agent platform runs on.
Application code lives in a separate repository.

New to Terraform? Read [`TERRAFORM-NOTES.md`](TERRAFORM-NOTES.md) first. It is written
from the mistakes made in this repository, not from documentation.

## Layers

Each layer is a separate directory with its own state file. A change to one cannot
affect another's state.

| Layer | Runs where | Applied by | Creates |
|---|---|---|---|
| `bootstrap/seed` | management account | a human, once, from a laptop | state bucket, GitHub OIDC provider, the two pipeline roles |
| `bootstrap/organization` | management account | pipeline, gated | `Workloads` OU, guardrail SCP, the member accounts |

### Why seed runs locally

It breaks two circular dependencies. State belongs in S3, but the bucket has to exist
before a configuration can use it. And the pipeline should authenticate by federation,
but neither the identity provider nor the role can be created by the pipeline that
needs them to authenticate at all.

Seed keeps local state for exactly one apply, then:

```bash
terraform init -migrate-state -backend-config=backend.hcl
terraform plan          # expect: No changes
rm terraform.tfstate*
terraform plan          # expect: No changes, with nothing on disk
```

State is never committed.

## The two pipeline roles

One role could not do both jobs, because GitHub changes the shape of the `sub` claim
depending on the trigger.

| Role | Permissions | Accepts `sub` | Used by |
|---|---|---|---|
| `eaf-bootstrap-plan-role` | `ReadOnlyAccess` + `*.tflock` writes | `repo:<owner>/<repo>:ref:refs/heads/*` | every plan |
| `eaf-bootstrap-pipeline-role` | `AdministratorAccess` | `repo:<owner>/<repo>:environment:bootstrap-apply` | apply, after approval |

The apply role deliberately does **not** also accept the main-branch claim. Allowing
it would mean any push to main gets admin with no approval, which is what the gate
exists to prevent.

`ReadOnlyAccess` alone cannot plan, because a plan takes the state lock. The plan role
has a scoped policy for `*.tflock` objects only, so "read-only" stays true of state.

## Workflows

| Workflow | Trigger | Credentials |
|---|---|---|
| `checks` | every push | none |
| `plan` | push touching `bootstrap/**` | plan role |
| `apply` | push to `main`, or manual dispatch | plan role, then apply role behind the gate |

`apply` runs two phases on purpose. The first plans with the read-only role and prints
the result. The second waits for approval, then applies **that saved plan**. So the
reviewer approves a plan they can read, rather than approving a plan that gets
generated afterwards.

Manual dispatch stays for two cases: the first account-creation run, which needs
emails typed in, and applying `seed`.

## Branching model

**One rule: `main` is prod, every other branch is dev.** No branch-name prefix is
required or recognised — nothing in this repository matches `feature/` or any other
convention.

| Branch | Bootstrap layers | Dev account layers | Prod account layers |
|---|---|---|---|
| any branch except `main` | plan only | **apply, no approval** | nothing |
| `main` | plan, then gated apply | apply | plan, then gated apply |

### Why the bootstrap layers have no dev/prod split

Branch-per-environment assumes two copies of the same thing. The bootstrap layers have
one target — the management account — and one state file each. There is no dev copy of
an organization to practise on, and `EAF-DEV` is not somewhere this code deploys into,
it is something this code creates.

Two environments need two state files. Bootstrap has one because it has one target.

### Why any branch may apply to dev without approval

Because the ceiling is enforced **above** the account, not by reviewing each change:

- The **SCP** on the `Workloads` OU applies to `EAF-DEV` exactly as it does to prod. A
  developer cannot create an IAM user, cannot make S3 public, cannot call Bedrock
  outside London. That holds regardless of what their Terraform says and cannot be
  overridden from inside the account.
- The **permissions boundary** created by the account-baseline layer caps the dev
  pipeline role.
- Control Tower's controls apply, because the OU is enrolled.

So unreviewed code reaching dev is a cheap mistake, not a dangerous one.

### The trade in dev, stated plainly

One dev account, one state file. If two branches apply, dev reflects whichever ran
last. The state lock prevents corruption — the second run waits — but it does not stop
one change overwriting another. Acceptable for a small team where dev is disposable.

The escape hatch, if it ever hurts, is per-branch state:

```hcl
key = "workloads/dev/${branch}/terraform.tfstate"
```

That creates real AWS resources per branch, which cost money and get forgotten. Do not
start there.

### The dev role's trust condition, when that layer is built

"Any branch except main" is two conditions on the same key, which IAM ANDs together:

```hcl
condition {
  test     = "StringLike"
  variable = "token.actions.githubusercontent.com:sub"
  values   = ["repo:${var.github_repository}:ref:refs/heads/*"]
}

condition {
  test     = "StringNotEquals"
  variable = "token.actions.githubusercontent.com:sub"
  values   = ["repo:${var.github_repository}:ref:refs/heads/main"]
}
```

### Open question worth deciding before that layer lands

If `main` never applies to dev, dev permanently reflects whichever branch applied last
and never converges on what was merged. The usual fix is for `main` to apply to dev
first and then to prod behind the gate, so dev always matches merged code. That still
satisfies "every non-main branch goes to dev only".

### Local iteration on dev

Merging in order to test is the wrong loop. For dev, apply from your machine:

```bash
aws sso login --profile eaf-dev
cd accounts/dev
terraform init -backend-config=backend.hcl
terraform apply
```

State still lives in S3, so this is not a private copy and the lock still applies.
Allowed for dev only. Prod gets no human credentials, only the gated pipeline.

## One-time setup

### 1. GitHub Environment — this is the approval gate

```
Settings > Environments > New environment > bootstrap-apply
  Required reviewers:    at least one person
  Deployment branches:   Selected branches -> main
```

Until reviewers are configured, the Environment exists but approves nothing. AWS can
only check the Environment's name; it cannot check that anyone clicked approve.

### 2. Branch protection

```
Settings > Branches > add a rule for main
  Require a pull request before merging
  Do not allow bypassing
```

AWS cannot enforce this. It only sees what the token says. Branch protection is what
makes `refs/heads/main` mean "reviewed".

### 3. Repository variables

`Settings > Secrets and variables > Actions > Variables`. Variables, not secrets —
none of these is a credential, and treating non-secrets as secrets makes the real
secrets harder to audit.

| Variable | Value |
|---|---|
| `AWS_REGION` | `eu-west-2` |
| `AWS_MANAGEMENT_ACCOUNT_ID` | `193027353132` |
| `AWS_STATE_BUCKET` | `eaf-bootstrap-tfstate-193027353132` |
| `AWS_PLAN_ROLE_ARN` | `arn:aws:iam::193027353132:role/eaf-bootstrap-plan-role` |
| `AWS_BOOTSTRAP_ROLE_ARN` | `arn:aws:iam::193027353132:role/eaf-bootstrap-pipeline-role` |
| `EAF_DEV_ACCOUNT_EMAIL` | a unique address you control |
| `EAF_PROD_ACCOUNT_EMAIL` | a different unique address |

Get the ARNs from seed:

```bash
cd bootstrap/seed && terraform output
```

### 4. Account emails — read before setting

AWS Organizations has **no API to change an account's email**. Set these once and do
not change them. A different value on a later run makes Terraform plan a change it
cannot perform, and it fails mid-apply.

Plus-addressing gives two unique addresses from one inbox:

```
you+eaf-dev@example.com
you+eaf-prod@example.com
```

Accounts also cannot be cleanly deleted. Closure takes 90 days and a closed account
still counts against the organization quota. `prevent_destroy` and
`ignore_changes = [email, name]` are on the resource as guards, but the real control
is getting the value right the first time.

## Local commands

```bash
make checks          # what CI runs with no credentials
make plan-org        # plan the organization layer
make policy-check    # render the SCP, run Access Analyzer, run the negative control
```

The AWS targets expect credentials in the environment.

## Validating policies

Reading policy HCL by eye does not work. Three bugs got in that way, and each would
have denied **nothing** while reading as a guardrail:

| Written | Problem |
|---|---|
| `bedrock:Converse` | an API name, not an IAM action |
| `s3:DeleteAccountPublicAccessBlock` | no such action |
| `accessanalyzer:DeleteAnalyzer` | the prefix is `access-analyzer` |

An unknown action inside a `Deny` denies nothing, with no error at apply time and none
at request time. So `plan` renders the policy from the plan and runs Access Analyzer
on it, then re-injects those three actions into a throwaway copy to confirm the
validator still rejects them. A clean result only means something if the check can
fail.

## This organization is not a sandbox

The management account belongs to an organization with 25 accounts, including client
and production work, managed by AWS Control Tower.

Everything here is **strictly additive**: a new OU, SCPs attached only to that OU, no
existing account moved, no existing policy modified. Anything that would change
another team's governance belongs in a conversation, not in a commit.
