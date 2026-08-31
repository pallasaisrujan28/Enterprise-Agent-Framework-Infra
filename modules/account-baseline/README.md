# `modules/account-baseline`

Per-account security baseline. Runs **inside** a member account via
`OrganizationAccountAccessRole`, after the account exists and Control Tower has
finished enrolling it.

```hcl
module "baseline" {
  source = "../../modules/account-baseline"

  org_prefix   = "eaf"
  account_name = "EAF-DEV"
  environment  = "dev"
  region       = var.region

  github_repository          = "acme/my-app"
  github_repository_owner_id = "194785418"
  github_repository_id       = "1324052608"

  budget_limit_usd   = 200
  budget_alert_email = "platform@example.com"
}
```

## What this does and does not create

Control Tower already provides CloudTrail (org-level, all regions), Config, and its own
IAM roles. Duplicating them causes conflicts or double billing, so this module leaves
them alone.

It adds GuardDuty, Security Hub with the FSBP standard, a permissions boundary, a GitHub
OIDC provider, a workload CI role, and a monthly budget alert.

The **account-level S3 public access block is deliberately not managed here.** The
guardrail SCP denies `s3:PutAccountPublicAccessBlock` for every principal in the
account, Terraform included. The SCP is the real protection, and AWS enables the block
by default for accounts created after April 2023.

## Inputs

| Name | Type | Default | Notes |
|---|---|---|---|
| `org_prefix` | string | — | Required. Lowercase, 2-12 chars. Prefixes every generated name |
| `account_name` | string | — | Required |
| `environment` | string | — | One of `dev`, `test`, `staging`, `prod` |
| `region` | string | — | Required. Appears in the region-qualified Security Hub standards ARN |
| `github_repository` | string | — | `owner/repo` permitted to assume the CI role |
| `github_repository_owner_id` | string | — | Required. Numeric, appears in the OIDC subject |
| `github_repository_id` | string | — | Required. Numeric, appears in the OIDC subject |
| `github_oidc_issuer_url` | string | `https://token.actions.githubusercontent.com` | Override only for GitHub Enterprise Server |
| `budget_limit_usd` | number | `100` | Alerts at 80% actual and 100% forecast |
| `budget_alert_email` | string | — | Required |

`region` and `github_repository_owner_id` **have no defaults on purpose.** Both once
did. A module that guesses its own region is not portable and the guess is invisible at
the call site; a defaulted owner ID silently applies one organisation's identity to
another's trust policy, producing a policy that never matches with no error at plan or
apply time.

## Outputs

`workload_ci_role_arn`, `workload_boundary_arn`, `workload_boundary_name`,
`github_oidc_provider_arn`, `guardduty_detector_id`, and `inventory`.

`workload_boundary_name` exists because a *name* is sometimes the only usable form. See
below.

`inventory` reports generated names as generated rather than as literals, so a reviewer
and `make iam-inventory` see the strings the apply will actually use.

## Renaming is destructive

Every generated name derives from `org_prefix`. **An IAM policy or role name is
immutable, so changing one is a destroy-and-create** — and `eaf-workload-boundary` is
referenced by the workloads layer while `eaf-workload-ci-role` survives workload
teardown.

`accounts/dev` and `accounts/prod` therefore pass `org_prefix = "eaf"`, which reproduces
the pre-existing names exactly. `tests/` pins those three names as literals so a change
to how they are built fails offline instead of proposing a replacement against a real
account.

## The boundary ARN is constructed, and that is correct here

Two statements inside the boundary's policy document have to name the boundary:
`AllowIAMWithBoundary`, which permits role creation only when the new role carries it,
and `DenyBoundaryRemoval`, which forbids detaching it.

That document is the `policy` body of `aws_iam_policy.workload_boundary`, so referencing
`aws_iam_policy.workload_boundary.arn` from inside it is a self-reference and Terraform
rejects the graph as a cycle. **There is no attribute to depend on, because the thing
being described does not exist yet.**

So the ARN is built from `local.boundary_name` — the same local that names the resource.
That does not restore the dependency edge an attribute reference would have created, but
it does remove the drift: a rename moves both together, and
`boundary_arn_cannot_drift_from_the_boundary_name` asserts they agree.

Elsewhere, prefer the attribute reference. A literal string creates no dependency edge,
so Terraform cannot know what must exist first and a rename breaks at apply time rather
than at plan time. This is a real exception, not a licence.

## The OIDC issuer is derived

The condition-key prefix on the CI role's trust policy
(`token.actions.githubusercontent.com:sub`) is derived from `github_oidc_issuer_url`,
the same input that configures the provider being federated. It is not written out
separately.

A trust policy naming a different issuer than its provider is valid JSON, applies
cleanly, and never matches — `AssumeRoleWithWebIdentity` just fails, with nothing
pointing at the mismatch. Deriving removes the opportunity. Same rule as
`modules/iam-role`.

## Known follow-ups

Both are behavioural changes against live resources, so neither belongs in a portability
change:

- The provider constraint is `>= 5.0.0`. The *shape* is now right — a module should not
  forbid a caller from choosing a newer major. Moving `accounts/*` to 6.x needs a
  reviewed plan, since neither commits a lock file.
- `aws_guardduty_detector.datasources` is deprecated in favour of
  `aws_guardduty_detector_feature`.

## Tests

```
make test                              # all modules
cd modules/account-baseline && terraform test
```

`command = plan` throughout, no credentials, confirmed passing with every AWS
environment variable unset.

One limitation worth knowing: `mock_provider` stubs every data source, including
`aws_iam_policy_document`, whose `json` is computed by the provider. The tests therefore
assert generated names and the constructed ARN — plain locals, read through `inventory`
— and **not** the rendered policy JSON. Whether the document is well-formed is covered
by `terraform validate` and by apply.
