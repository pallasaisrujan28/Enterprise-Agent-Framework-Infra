# `modules/iam-role`

The only way an IAM role is created in this repository.

No root module writes `resource "aws_iam_role"` directly. One creation path means a
convention added here applies everywhere on the next apply, instead of being a
comment that new code is free to ignore.

## Why this exists

Roles were previously added one at a time to fix failures. Each addition was
individually reasonable; the set became untrackable. Three specific things allowed
that:

- **Three naming schemes.** `bootstrap/seed` used `${org_prefix}-<purpose>-role`,
  `account-baseline` used hardcoded literals, `workloads` mixed
  `${cluster_name}-<purpose>-role` with literals. Given a role name, no rule told you
  which directory declared it.
- **No environment segment in some names**, so a role name did not say which account
  it belonged to.
- **No inventory**, so "should this role exist?" required grepping every layer.

This module fixes the first two by construction. The inventory and the orphan check
(`make iam-inventory`, `make iam-orphans`) fix the third.

## Naming

```
${org_prefix}-${environment}-${layer}-${purpose}-role
```

Generated, never passed in. `eaf-dev-platform-deployer-role` tells you the
organisation, the environment, the layer that owns it, and what it does. `layer` is
the locator: it names the directory to open.

## Usage

### GitHub Actions OIDC

```hcl
module "deployer_role" {
  source = "../../modules/iam-role"

  org_prefix  = var.org_prefix
  environment = "dev"
  layer       = "accounts"
  purpose     = "platform-deployer"
  description = "Assumed by the infra pipeline to apply the platform layer in EAF-DEV."
  owner       = "platform-team"

  boundary_arn = aws_iam_policy.deployer_boundary.arn # attribute, never a string

  trust = {
    type = "github_oidc"
    github_oidc = {
      oidc_provider_arn = aws_iam_openid_connect_provider.github.arn
      owner             = "pallasaisrujan28"
      owner_id          = var.github_repository_owner_id
      repository        = "Enterprise-Agent-Framework-Infra"
      repository_id     = var.github_repository_id
      contexts          = ["environment:dev"]
    }
  }

  pass_role_arns = [
    module.cluster_role.arn,
    module.node_role.arn,
  ]
}
```

### IRSA

```hcl
module "agent_role" {
  source = "../../modules/iam-role"

  org_prefix  = var.org_prefix
  environment = "dev"
  layer       = "platform"
  purpose     = "agent"
  description = "Assumed by the agent pod via IRSA to call Bedrock and read its workspace bucket."
  owner       = "platform-team"

  boundary_arn = data.aws_iam_policy.workload_boundary.arn

  trust = {
    type = "eks_irsa"
    eks_irsa = {
      oidc_provider_arn = aws_iam_openid_connect_provider.eks.arn
      # The issuer host is derived from this ARN — do not pass it separately.
      namespace         = "eaf"
      service_account   = "eaf-agent"
    }
  }

  inline_policies = {
    bedrock-invoke = data.aws_iam_policy_document.agent_bedrock.json
  }
}
```

## The two mistakes this module makes unreachable

### 1. The GitHub `sub` claim is mutually exclusive by job context

GitHub documents that the `ref:` subject form applies **only** when the job does not
reference an environment and was not triggered by a pull request. Adding
`environment: dev` to a job **replaces** the `ref:` segment — it does not append.

This is why `pipeline.yml` carries the comment *"with `environment: dev` the OIDC sub
becomes `environment:dev` which the deployer role trust policy does not accept"*, and
why the workaround taken was to delete the environment — discarding the approval gate
rather than fixing the trust policy.

The module takes `contexts` as an explicit list, validated against the four real
shapes plus `job_workflow_ref:` and `*`. A bare branch name — the most common
mistake, and one that fails with no useful message — is rejected at plan time.

| Job context | Subject |
|---|---|
| references an `environment` | `repo:.../...:environment:NAME` |
| `pull_request`, no environment | `repo:.../...:pull_request` |
| branch push, no environment | `repo:.../...:ref:refs/heads/BRANCH` |
| tag, no environment | `repo:.../...:ref:refs/tags/TAG` |

### 2. Immutable subject claims

Repositories created after 15 July 2026 use a subject embedding the owner and
repository IDs — `repo:OWNER@OWNER-ID/REPO@REPO-ID:CONTEXT` — and the IDs cannot be
removed. **This repository uses that format.** A trust policy written in the older
`repo:OWNER/REPO:...` form silently never matches: no error, just a failed
`AssumeRoleWithWebIdentity`.

`immutable_subject` defaults to `true` and requires `owner_id` and `repository_id`.
Set it to `false` only for a repository known to be on the legacy format.

### 3. The issuer host is derived, never restated

Every OIDC condition key is prefixed with the provider's issuer host and path
(`token.actions.githubusercontent.com:sub`, `oidc.eks.<region>.amazonaws.com/id/<id>:aud`).
The module derives that prefix from `oidc_provider_arn` by splitting on
`:oidc-provider/`. There is no input for it.

Two reasons it is not a literal or an input:

- Writing `token.actions.githubusercontent.com` into the module is correct only for
  github.com. GitHub Enterprise Server issues tokens from the appliance host, so a
  hardcoded issuer makes the module quietly github.com-specific.
- An issuer accepted as an input *alongside* the ARN can disagree with it. The result
  is valid JSON that applies cleanly and never matches — the same silent-failure class
  as the subject format above. Deriving removes the opportunity to get them apart.

Pass the provider resource's `.arn` attribute. Passing an issuer URL such as
`https://token.actions.githubusercontent.com` is rejected at plan time.

## Permissions boundaries

`boundary_arn` is required, with a loud opt-out (`boundary_exemption_reason`).
Supplying neither, or both, is a plan-time error.

**A boundary grants nothing.** Effective permissions are the intersection of the
identity policy and the boundary, so a boundary that omits a service denies it
regardless of what the attached policy allows.

This matters because the two boundaries in this repository are **not
interchangeable**:

| Boundary | For | Contains |
|---|---|---|
| `*-workload-boundary` | Runtime roles — the agent pod, CI push | Bedrock, S3, ECR, secrets read, logs |
| `*-deployer-boundary` | Infrastructure roles — layer deployers | Denies reach; allows what the layers create |

Verified with `iam simulate-custom-policy`, the workload boundary returns
`implicitDeny` for `eks:CreateCluster`, `ec2:CreateVpc`, `kms:CreateKey`,
`iam:CreateOpenIDConnectProvider`, `ssm:PutParameter` and `secretsmanager:CreateSecret`.
Attaching it to a deployer guarantees L1 fails on first apply — and fails naming the
action, not the boundary.

Before attaching any boundary:

```sh
aws iam simulate-custom-policy \
  --policy-input-list "$(aws iam get-policy-version \
      --policy-arn <boundary> --version-id v1 \
      --query 'PolicyVersion.Document' --output json)" \
  --action-names eks:CreateCluster ec2:CreateVpc iam:CreateOpenIDConnectProvider
```

## Policies

`inline_policies` and `managed_policy_arns` are realised as `aws_iam_role_policy` and
`aws_iam_role_policy_attachment`. The `inline_policy` block and `managed_policy_arns`
argument **on `aws_iam_role` itself are deprecated** by the provider, and mixing them
with the standalone resources causes resource cycling.

`exclusive_policy_management` (default `true`) adds
`aws_iam_role_policies_exclusive` and `aws_iam_role_policy_attachments_exclusive`, so
a policy attached out of band is removed on the next apply. Reconciliation happens on
apply, not continuously — which is why `make iam-orphans` exists as well. This catches
unmanaged policies on a managed role; the orphan check catches unmanaged roles.

`pass_role_arns` generates a scoped `iam:PassRole` policy and rejects `"*"`. A deployer
missing `PassRole` fails with an error naming the target role, not `PassRole`, which is
slow to diagnose.

## Tags

Mandatory and not overridable — `extra_tags` is merged first, so generated values win:
`ManagedBy`, `ManagedByModule`, `OrgPrefix`, `Environment`, `Layer`, `Purpose`,
`Owner`, `TrustType`, `Boundary`.

## Outputs

`arn`, `name`, `unique_id`, and `inventory` — a structured record each layer
aggregates into an `iam_roles` output. `inventory.trusted_subjects` flattens exactly
who may assume the role, so an over-broad trust policy is visible without reading
JSON.

## Tests

```sh
terraform -chdir=modules/iam-role test
```

18 tests, `command = plan` throughout, a few seconds. Half assert that bad input is
**rejected** — a guardrail nobody has watched fail is not known to work.

**No credentials of any kind.** Verified by running the suite with
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_PROFILE` and
`AWS_DEFAULT_REGION` unset. The test provider sets `skip_credentials_validation`,
`skip_requesting_account_id` and `skip_metadata_api_check`, which is sufficient for a
plan whose values are all known from configuration. No `access_key` or `secret_key` is
set, and none is needed.

## Version constraints

This module constrains **minimums only** (`>= 1.9.0`, `>= 6.0.0`), following
HashiCorp's guidance that reusable modules set only a lower bound and root modules use
`~>` for both bounds.

`>= 1.9.0` because cross-variable references in `validation` blocks need 1.9.
`>= 6.0.0` because of the two exclusive-management resources.
