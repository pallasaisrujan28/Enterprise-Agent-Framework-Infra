# `modules/ecr-repository`

One ECR repository, with immutable tags, scan-on-push, encryption and a lifecycle policy.

```hcl
module "ecr" {
  source   = "../../../modules/ecr-repository"
  for_each = toset(["eaf/agent", "tools/firecrawl"])

  name        = each.key
  org_prefix  = var.org_prefix
  environment = "dev"
  owner       = "platform-team"

  force_delete               = true   # see below — this default is wrong for dev
  untagged_image_expiry_days = 7
  max_tagged_images          = 30
}
```

A slash in the name is a **naming convention, not a hierarchy**. ECR has no folders;
`eaf/agent` is one repository whose name happens to contain a slash.

## Immutable tags, and the defect that motivated the default

`image_tag_mutability` defaults to `IMMUTABLE`. A tag, once pushed, can never point at a
different image — which is what makes a rollback reliable and an audit possible.

**This repository has already been bitten by the interaction.** An earlier `eaf/agent` was
`IMMUTABLE` while its build workflow pushed both `:${sha}` *and* `:latest` on every run. An
immutable repository refuses to move an existing tag, so the **first** push succeeded and
every one after it failed. The `tools/*` repositories had the mirror-image problem —
`MUTABLE` with `:latest`, so nothing recorded which image was actually running.

**The resolution is not a middle setting.** It is to stop deploying `:latest`. Keep
`IMMUTABLE` and reference images by commit SHA or digest.

AWS does offer a middle setting — the API accepts `IMMUTABLE`, `MUTABLE`,
`IMMUTABLE_WITH_EXCLUSION` and `MUTABLE_WITH_EXCLUSION`, verified against the live API —
and `mutable_tag_exclusions` drives it. Reaching for it to fix a failing push is treating
the symptom. Every tag listed there is a tag that can be repointed, so it is a tag nothing
should be deployed from.

Two preconditions keep the pair honest: exclusions without an `_WITH_EXCLUSION` mode are
rejected (the API rejects them too, but at apply), and an `_WITH_EXCLUSION` mode with no
exclusions is rejected because it behaves identically to the plain mode while reading as
though it does not.

## The lifecycle bug this module had before it was ever applied

An ECR lifecycle rule **selects the images it acts on**. There is no exclusion filter.

The first version of this module took `protected_tag_prefixes` and put them in the rule's
`tagPatternList` — which selects them **for expiry**. It would have deleted precisely the
release tags it claimed to protect.

So the input is `expirable_tag_prefixes`, phrased as an allowlist: only tags matching are
subject to the count, and anything else survives indefinitely. Empty means the count
applies to everything, which is the simple and usually correct choice.

`untagged_image_expiry_days` runs at priority 1 and the count rule at priority 2. ECR
evaluates in ascending order, and that order matters: reversed, the count rule could delete
a tagged image while unreferenced ones survived.

**Both rules are needed on an immutable repository.** The untagged rule alone would rarely
fire, because immutable tags are never orphaned by a re-push — untagged images come from
multi-architecture builds and from deletions. And the count rule alone leaves no bound on
images that pile up, since every build adds a tag that is never replaced.

## `force_delete` — the default is safe and probably wrong for you

Defaults to `false`, which **refuses to delete a repository that still holds images**. That
makes `terraform destroy` **fail** on any repository ever pushed to.

That is correct for anything holding artefacts someone might need. It is the wrong default
for an environment torn down and rebuilt on purpose: there, a destroy that stops halfway
leaves the rest of the layer standing and billing.

Set it `true` where images are rebuildable from source — and know that doing so means a
destroy silently discards them. `inventory.destroyable_with_images` reports which you have.

## Encryption

`kms_key_arn` is optional. Null gives `AES256`, which is still encryption at rest with an
AWS-owned key. A CMK buys an auditable key policy and revocation by disabling the key; it
costs per key per month and adds a policy to maintain.

**Cannot be changed after creation.** Switching means a new repository.

## Cross-account pull

`pull_principals` creates a repository policy. Empty is correct for the common case: a
principal in the **same** account pulls using its own IAM permissions, and listing it here
would be redundant.

The policy grants three actions and deliberately **not** `ecr:GetAuthorizationToken` —
that is an account-level action against the registry, which a *repository* policy cannot
grant. Listing it would apply cleanly and look like it did something; the pulling principal
must hold it in its own IAM policy.

Built with `jsonencode` rather than `aws_iam_policy_document`, matching
`modules/iam-role`. The data source is computed by the provider, so under a mocked provider
its `json` is a stub — and for a policy whose point is which actions it does *not* grant,
that is the difference between a test and a decoration.

## Inputs

Required: `name`, `org_prefix`, `environment`, `owner`.

| Optional | Default | Notes |
|---|---|---|
| `image_tag_mutability` | `"IMMUTABLE"` | |
| `mutable_tag_exclusions` | `[]` | Max 5. Only with an `_WITH_EXCLUSION` mode |
| `scan_on_push` | `true` | Basic scanning, free, per-repository |
| `kms_key_arn` | `null` | `AES256` otherwise. Create-time only |
| `untagged_image_expiry_days` | `7` | Null disables |
| `max_tagged_images` | `30` | Null disables |
| `expirable_tag_prefixes` | `[]` | An **allowlist** of what may be expired |
| `force_delete` | `false` | See above |
| `pull_principals` | `[]` | Cross-account only |
| `extra_tags` | `{}` | Merged first; mandatory tags win |

## Outputs

`name`, `arn`, `repository_url`, `registry_id`, `inventory`.

**`repository_url`** is what a build pushes to and a manifest references. Pass it rather
than reconstructing `<account>.dkr.ecr.<region>.amazonaws.com/<name>` — a reconstructed
string creates no dependency edge, so a change breaks the consumer silently at apply.

`inventory` reports three things as plain booleans rather than leaving them to be inferred:
`tags_are_immutable` (true only for the plain mode), `lifecycle.unbounded` (nothing limits
growth, so the bill rises quietly), and `destroyable_with_images`.

## Tests

```sh
terraform -chdir=modules/ecr-repository test
```

17 tests, `command = plan`, no credentials. Three pin the lifecycle-rule semantics
specifically, because getting the allowlist backwards deletes data and passes review.
