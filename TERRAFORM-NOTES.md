# Terraform and OIDC — Working Notes

A reference for this repository. Written as questions came up while building the
seed layer, so it covers the things that actually caused confusion rather than a
generic tutorial.

Anything marked **VERIFIED** was tested in this repo, not recalled.

---

## 1. The one rule that explains most confusion

**Every `.tf` file in a single directory is one program.** Terraform concatenates
them before doing anything. File names are for humans only — Terraform does not
care.

```
bootstrap/seed/
├── provider.tf     ─┐
├── variables.tf     │  All read as ONE unit.
├── main.tf          │  Splitting them is organisation,
├── oidc.tf          │  not structure.
├── iam.tf           │
└── outputs.tf      ─┘
```

Consequences that surprise people:

- **Order does not matter**, within or between files. Terraform builds a
  dependency graph from what references what.
- **You never sequence things manually.** If A references B, B is created first.
- A name must be unique across the *whole directory*, not per file.

---

## 2. Block types

```hcl
terraform { }    # settings: required version, providers, where state lives
provider  { }    # how to talk to a platform (AWS, Azure, GCP...)
variable  { }    # an input
locals    { }    # a value computed once and reused
resource  { }    # CREATE something
data      { }    # READ something that already exists
output    { }    # publish a value for other layers or for humans
module    { }    # call reusable code from elsewhere
```

### `resource` vs `data` — the distinction to internalise

```hcl
resource "aws_iam_openid_connect_provider" "github" { }   # makes a new one
data     "aws_iam_openid_connect_provider" "github" { }   # finds an existing one
```

`resource` creates and owns. If you delete the block, Terraform destroys the thing.
`data` only reads. Deleting the block destroys nothing.

This matters for shared infrastructure. An OIDC provider is account-level — AWS
permits one per URL per account. In an account where one already exists, `resource`
would fail with `EntityAlreadyExists`, and importing it would mean our `destroy`
deletes another team's trust anchor. So we `data` it instead.

---

## 3. Referencing things

| Syntax | Refers to |
|---|---|
| `var.region` | an input variable |
| `local.account_id` | a computed local |
| `aws_s3_bucket.state.arn` | attribute of something **we created** |
| `data.aws_caller_identity.current.account_id` | attribute of something **we looked up** |
| `module.vpc.vpc_id` | an output of a module |
| `each.key` / `each.value` | current item inside `for_each` |
| `count.index` | current index inside `count` |

Created resources have **no prefix**. Looked-up ones are prefixed `data.`. That is
how you tell "we own this" from "we found this" at a glance.

---

## 4. `locals` rules — **VERIFIED**

### The block is PLURAL, the reference is SINGULAR

This inconsistency catches everyone:

```hcl
locals {           # <- block:     locals
  a = "hello"
}

output "x" {
  value = local.a  # <- reference:  local.   NOT locals.
}
```

`locals.a` is not valid. It is always `local.a`.

### `locals` is a reserved keyword; the names inside are yours

You cannot rename the block. The reserved block types are:

```hcl
terraform { }   provider { }   variable { }   locals { }
resource  { }   data     { }   output   { }   module { }
```

Inside, `a`, `b`, `github_oidc_arn` are names you choose — anything that is a valid
identifier.

### Multiple blocks, across multiple files — a working example

Tested end to end with three files in one directory:

```hcl
# a.tf
locals {
  a = "hello"
}
```

```hcl
# b.tf
locals {
  b = "world"
}
```

```hcl
# c.tf   -- references locals from BOTH other files
locals {
  combined = "${local.a} ${local.b}"
  shouty   = upper(local.combined)
}

output "combined" { value = local.combined }
output "shouty"   { value = local.shouty }
```

Actual result:

```
combined = "hello world"
shouty   = "HELLO WORLD"
```

### The rules this demonstrates

- **Multiple `locals` blocks are allowed** — any number, in any file.
- **Locals are directory-wide.** They are not scoped to a block, a file, or the
  resources near them. `local.a` declared anywhere is visible everywhere in that
  directory.
- **Order does not matter.** `c.tf` uses values from `a.tf` and `b.tf` with no
  declaration order and no imports.
- **A local may reference another local**, including one in a different file.
- **Duplicate names across blocks are an error** — tested:
  `Error: Duplicate local value definition`. Names must be unique across the whole
  directory, not per block.

Use locals to name something once rather than repeating an expression, and to give
an unreadable expression a readable name.

---

## 5. Providers can be any platform

`provider` is a plugin. AWS is one of hundreds.

```hcl
provider "aws"     { region = "eu-west-2" }
provider "azurerm" { features {} }
provider "google"  { project = "my-project" }
provider "github"  { owner = "my-org" }        # not a cloud at all
provider "tls"     { }
```

You can use several in one configuration.

### Provider aliases — how one config touches two accounts

This is how the bootstrap pipeline reaches into member accounts:

```hcl
provider "aws" {
  region = "eu-west-2"                # the default one
}

provider "aws" {
  alias  = "dev"                      # a SECOND aws provider
  region = "eu-west-2"
  assume_role {
    role_arn = "arn:aws:iam::111111111111:role/OrganizationAccountAccessRole"
  }
}

resource "aws_iam_role" "something" {
  provider = aws.dev                  # explicitly use the second one
  # ...
}
```

`OrganizationAccountAccessRole` is created automatically by AWS Organizations in
every member account and trusts the management account. That is what makes
cross-account bootstrap possible without storing any credentials.

---

## 6. How files in DIFFERENT directories share things

Not automatic. A different directory is a **different program with different
state**. Two mechanisms:

### Call it as a module

```hcl
module "baseline" {
  source = "../_modules/account-baseline"   # local path
  # or a pinned git tag:
  # source = "git::https://github.com/org/repo.git//modules/vpc?ref=v1.1.0"

  account_name = "eaf-dev"                  # inputs
}

# then use its outputs
resource "x" "y" {
  role_arn = module.baseline.cicd_role_arn
}
```

A module is just a directory of `.tf` files. Its `variable` blocks are its inputs,
its `output` blocks are what it returns. Nothing is published anywhere — with a git
source, `terraform init` clones the repo and uses the folder locally. **The git tag
IS the version.**

### FIRST: within one directory you need none of this — **VERIFIED**

The common question is "file B creates an IAM role, file A needs it — do I apply B
first, then read B's output in A?"

**No.** Within one directory there is no ordering to manage and no output needed.
Just reference the thing:

```hcl
# iam.tf
resource "aws_iam_role" "agent" {
  name = "eaf-dev-agent"
}

# runtime.tf
resource "aws_bedrockagentcore_runtime" "agent" {
  role_arn = aws_iam_role.agent.arn      # <- THIS reference IS the dependency
}
```

That one reference is the entire mechanism. Terraform sees runtime needs role,
creates the role first, in a single `terraform apply`.

**Proof from this repository.** `iam.tf` never mentions `oidc.tf`, yet
`terraform graph` shows the chain Terraform derived by itself:

```
aws_iam_role.bootstrap_pipeline            (declared in iam.tf)
  -> data.aws_iam_policy_document.trust    (declared in iam.tf)
    -> aws_iam_openid_connect_provider     (declared in oidc.tf)
```

The link is the reference to `local.github_oidc_arn`. Files are irrelevant to
ordering.

`terraform graph` is worth knowing for exactly this — it prints the dependency graph
so you can check Terraform understood what you meant.

### So what is `output` actually for?

| Purpose | Output needed? |
|---|---|
| Passing a value between files in the **same** directory | **No** — reference it directly |
| Publishing a value to a **different** directory or a parent module | **Yes** |
| Showing a human a value after apply | Yes |
| Feeding a value to a script or Makefile (`terraform output -raw`) | Yes |

Outputs are the **public interface** of a directory. Anything not declared as an
output cannot be read from outside. That is a useful boundary, not just ceremony.

### The escape hatch, needed rarely

```hcl
resource "x" "y" {
  depends_on = [aws_iam_role.agent]   # force ordering with NO reference
}
```

For real dependencies Terraform cannot see — IAM eventual consistency is the
classic case. Reaching for `depends_on` frequently usually means you are missing a
reference you could have used instead.

### Read another layer's state

```hcl
data "terraform_remote_state" "seed" {
  backend = "s3"
  config = {
    bucket = "eaf-bootstrap-tfstate-193027353132"
    key    = "bootstrap/seed/terraform.tfstate"
    region = "eu-west-2"
  }
}

# only values that layer declared as `output` are readable
locals {
  bucket = data.terraform_remote_state.seed.outputs.state_bucket
}
```

This is why `outputs.tf` matters: **outputs are the public interface of a layer.**
Anything not declared as an output cannot be read by another layer.

Prefer this over hardcoding an ARN. A hardcoded value drifts silently the moment
the other layer changes, and the failure shows up as a confusing permission error.

---

## 7. `count`, `for_each`, and why you see `[0]`

### `count` turns a resource into a list

```hcl
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0
}
```

- `count = 1` → a list with one item → address it as `github[0]`
- `count = 0` → an empty list → nothing is created

That is the whole reason for the `[0]` in our code. With `count`, even a single
resource is a list, so it needs an index.

### The create-or-lookup pattern

```hcl
data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1     # opposite count
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_arn = var.create_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn   # the one we made
    : data.aws_iam_openid_connect_provider.github[0].arn  # the one already there
}
```

`condition ? a : b` is if/else on one line. Exactly one of the two exists at any
time, and the local hides that so the rest of the code just uses
`local.github_oidc_arn`.

### `for_each` is usually better than `count`

```hcl
resource "aws_organizations_account" "this" {
  for_each = var.accounts        # a map
  name     = each.key
  email    = each.value.email
}
```

Addressed by **key**, not index: `aws_organizations_account.this["eaf-dev"]`.

**Why this matters:** with `count`, removing the *first* item shifts every later
item's index, and Terraform sees that as "destroy and recreate everything after it".
With `for_each`, keys are stable, so removing one item affects only that item. Use
`for_each` for anything that is a set of named things.

---

## 8. Verifying what exists — you should never check the cloud by hand

Three read-only commands answer everything:

| Command | Question |
|---|---|
| `terraform state list` | What does Terraform *believe* it manages? |
| `terraform plan` | Does that belief match **the code** and **the real cloud**? |
| `terraform show` | Full recorded detail of a resource |

**`plan` queries the real provider every time it runs** (a refresh), then compares
three things: your code, the state file, and reality.

So **`No changes. Your infrastructure matches the configuration.`** is a three-way
agreement. That is a stronger statement than eyeballing the AWS console or the CLI,
which only tells you about one of the three.

**VERIFIED** in this repo: after applying seed, `plan` reported no changes; changing
`github_branch` from `main` to `develop` immediately produced an in-place update to
the role's trust policy — proving it had genuinely fetched the current policy rather
than answering from cache.

`plan` is read-only and safe to run whenever.

---

## 9. State — what it is and why it moves to S3

State is Terraform's notebook: which real resources correspond to which blocks in
your code.

Without it, Terraform cannot tell "create this" from "this already exists". Lose it
and Terraform tries to create everything again, then fails with
`EntityAlreadyExists` — the resources are fine, but Terraform no longer knows it
owns them, which is harder to unpick than a clean deletion.

**Why remote (S3):**

- A laptop is not a safe single copy
- Two people running apply at once would overwrite each other; a **lock** prevents it
- CI runners are ephemeral and start with nothing

**Locking:** `use_lockfile = true` uses S3 natively. Generally available since
Terraform 1.11; the older DynamoDB lock table arguments are **deprecated**. Most
tutorials and reference repos still show DynamoDB — they predate the change.

### Bootstrap is two-phase, and this is not optional

```
Phase 1   backend block COMMENTED OUT. State is local.
          Apply creates the state bucket, among other things.

Phase 2   uncomment the backend, then:
              terraform init -migrate-state -backend-config=backend.hcl
          Terraform copies local state into the bucket it just created.

Verify    terraform plan  →  "No changes"
          delete the local state file
          terraform plan  →  "No changes" AGAIN, with nothing on disk
```

The second check is the one that proves it. Mildly circular — the bucket holding
the state was created by the run whose state now lives in it — and unavoidable: you
cannot store state in a bucket that does not exist.

**No state file is ever committed to git.** It contains resolved resource
attributes, sometimes sensitive, and git history is hard to redact.

### Partial backend configuration

The bucket name contains an account id, so it cannot be hardcoded if the same code
must serve several accounts:

```hcl
terraform {
  backend "s3" {}          # empty — values supplied at init
}
```

```bash
terraform init -backend-config=backend.hcl
```

When switching between accounts use `-reconfigure`, **not** `-migrate-state`.
`-migrate-state` would copy one account's state over another's, which is the
opposite of intended and not obviously wrong until something gets destroyed.

---

## 10. Saved plan files, and the "stale plan" error

```bash
terraform plan -out=tf.plan     # save the computed plan to a file
terraform apply tf.plan          # apply that exact file
```

**Why bother:** without `-out`, `apply` re-plans from scratch. The diff a human
reviewed and the diff that executes are then two different computations. In a
pipeline, always plan to a file and apply that file.

**Why it goes stale:** the plan file records the state's serial number — a counter
that increments on every change. On apply, Terraform checks the serial still
matches. If state moved on, the recorded actions may no longer be valid, so it
refuses.

**What happened here, honestly:** the apply printed `Error: Saved plan is stale` and
looked like a failure. The resources had in fact been created and state written,
which is why an immediate retry reported `0 added`. **I cannot say with certainty
why the serial moved**, because nothing should have touched state in between. Rather
than invent a tidy explanation:

> **The lesson: do not trust the message, run `terraform plan`.** A plan reporting
> no changes proves code, state and reality agree, whatever any previous command
> printed.

---

## 11. OIDC — what the token actually is

### The problem it solves

The old way: create an AWS access key, paste it into GitHub secrets. That key is
permanent, sits in two places, and has to be rotated by someone who remembers to.

OIDC replaces it: **GitHub proves who it is with a short-lived signed token, and
AWS swaps that for temporary credentials.** Nothing stored, nothing to rotate.

### The token is a JWT with claims

A JWT is a signed JSON document. The named fields inside it are **claims**:

| Claim | Short for | Value for our pipeline |
|---|---|---|
| `iss` | issuer — who signed it | `https://token.actions.githubusercontent.com` |
| `aud` | audience — who it is for | `sts.amazonaws.com` |
| `sub` | **subject** — what the token is about | `repo:pallasaisrujan28/Enterprise-Agent-Framework-Infra:ref:refs/heads/main` |

**`repo:owner/repo:ref:...` is NOT the token.** It is one claim *inside* the token.
The token itself is a long signed blob.

**Why the owner is a person's username:** GitHub composes `sub` from the
repository's full name, which is `owner/repo`. A repo owned by a user has that
user's name as owner. Move the repo into a GitHub organisation and `sub` changes to
`repo:that-org/...`, and the trust policy must be updated to match.

### The `sub` shape depends on what triggered the run

```
repo:owner/repo:ref:refs/heads/main      push to the main branch
repo:owner/repo:pull_request             a pull request
repo:owner/repo:environment:prod         a job declaring `environment: prod`
```

This is the whole basis of the security model.

### Why exact matching matters — the most important line in this repo

```hcl
condition {
  test     = "StringEquals"                            # exact
  variable = "token.actions.githubusercontent.com:sub"
  values   = ["repo:owner/repo:ref:refs/heads/main"]
}
```

The tempting shortcut:

```hcl
  test   = "StringLike"                # DO NOT
  values = ["repo:owner/repo:*"]
```

That reads as "our repository", which sounds fine. But `*` also matches
`:pull_request` — so **anyone opening a pull request, including from a fork, gets a
workflow run that can assume the role.** For the bootstrap role, that is
AdministratorAccess in the management account.

The bootstrap role's permissions cannot be narrowed — creating accounts, OUs and
SCPs needs org administration, and no narrower managed policy covers it. So **the
trust policy is the only control**, and its strictness is not stylistic.

### The `environment:` form is stronger still

GitHub writes `environment:prod` into `sub` **only if the job actually ran in that
GitHub Environment**. If that environment requires reviewers, the claim is
cryptographic proof a human approved the run.

Binding a role's trust to that claim moves the approval gate out of GitHub
configuration and into AWS. Someone who switches off the reviewer requirement does
not gain the ability to deploy — they get a token without the claim, and
`AssumeRole` fails.

### Where `owner/repo` is validated — and where it is not

Two places, **neither of which checks the repo exists**:

1. **Terraform**, format only:
   ```hcl
   validation {
     condition = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
   }
   ```
   Catches a missing slash. Does not check ownership or existence.

2. **AWS at runtime**, the real check: comparing the token's `sub` against the
   trust policy.

**So a typo fails late.** `terraform apply` succeeds happily; the pipeline then
fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity`. Nothing
catches it earlier.

### One provider per account, not one shared from the root

Considered and rejected: a single OIDC provider in the management account with roles
chained into members.

| | Per account | Hub in root |
|---|---|---|
| Providers to manage | one each | one total |
| Blast radius of a compromised CI role | that account | **every account** |
| dev vs prod separation | enforced by trust conditions | becomes "which ARN the YAML passes" |
| Session length | 1 hour, renewable | **chained sessions capped at 1 hour, cannot be extended** |

An OIDC provider is free and never changes after creation, so "one per account" is
not real overhead. The blast-radius difference is.

---

## 12. The AWS account creation trap

`aws_organizations_account` has `email` as a **required** attribute. The provider
schema does not flag it as force-new, so Terraform will attempt an in-place update
if it changes — but **AWS Organizations has no API to change an account's email**,
so that update fails at apply time, possibly after other changes have landed.

And AWS accounts are close to un-deletable: closure takes 90 days and closed
accounts still count against your quota.

**Therefore emails must be stable across runs.** A pipeline that prompts for the
email on *every* run is dangerous — a different or empty value on a later run
produces a plan that tries to change an account.

The safe shape:

- **First creation:** `workflow_dispatch` with required email inputs. A deliberate
  manual run, which is right for creating accounts.
- **Afterwards:** emails stored outside the repo (SSM Parameter Store or a GitHub
  variable) and read by Terraform, so routine runs are stable and never re-prompt.
- **Always:** `lifecycle { prevent_destroy = true }` on every account resource.

Use `for_each` over a map so adding an account later is one map entry, not a new
folder.

---

## 13. Failures that happen late rather than early

Worth knowing, because each one costs an hour the first time.

| Mistake | When it surfaces |
|---|---|
| Typo in `owner/repo` | Pipeline run, as an auth failure |
| `StringLike` instead of `StringEquals` | Never — it just quietly permits more |
| Wrong `environment:` name vs the workflow | Pipeline run, as an auth failure |
| Missing GitHub variable | Auth failure with an empty ARN, not "you forgot this" |
| `vars.` vs `secrets.` in a workflow | Empty string, then a confusing auth error |
| Backend `-migrate-state` when switching accounts | State from one account copied over another |
| Account email changed | Apply-time failure, mid-run |

For the GitHub variable case, add a guard step that fails fast with a clear message
rather than letting an empty value produce a mysterious error.

---

## 14. Command reference

```bash
# setup
terraform init                                  # download providers, configure backend
terraform init -backend-config=backend.hcl      # partial backend config
terraform init -reconfigure -backend-config=...  # SWITCH backend, do not copy state
terraform init -migrate-state -backend-config=... # MOVE state to a new backend

# inspect — all read-only and safe
terraform state list                            # what Terraform manages
terraform plan                                  # code vs state vs reality
terraform show                                  # recorded detail
terraform output                                # this layer's published values
terraform providers schema -json                # what a resource actually supports

# change
terraform fmt -recursive                        # canonical formatting
terraform validate                              # syntax and references
terraform plan -out=tf.plan                     # save the reviewed plan
terraform apply tf.plan                         # apply exactly that
terraform destroy                               # remove everything in this state
```

**In a pipeline, always `plan -out` then `apply` that file.** Otherwise the reviewed
diff and the applied diff are different computations.

---

## 15. Ideas parked for later

**Account creation through a request workflow.** A Jira board or form feeding an
approval that triggers the account-creation pipeline, rather than a hand-run
`workflow_dispatch`. Sensible once accounts are created often enough to justify it.
The Terraform underneath does not change — only what triggers it.

**ArgoCD or a similar GitOps controller.** Relevant if Kubernetes arrives. Terraform
would still own the AWS layer.
