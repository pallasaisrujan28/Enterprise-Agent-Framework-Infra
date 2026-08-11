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

## 15. `data` versus `resource` — read it, or own it

Same AWS thing, two different intents. This distinction causes more confusion than
any syntax rule.

```hcl
resource "aws_iam_openid_connect_provider" "github" { }   # I OWN it
data     "aws_iam_openid_connect_provider" "github" { }   # I only READ it
```

| | `resource` | `data` |
|---|---|---|
| Creates | yes | no |
| Recorded in state | yes | no, re-read each run |
| `terraform destroy` | deletes it | cannot touch it |
| Used for | things this configuration owns | things someone else owns |

### The create-or-reference toggle

AWS permits **one OIDC provider per URL per account**, and that provider is shared
by every project in the account. So a configuration has to handle both "none exists"
and "one exists already":

```hcl
data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1     # look it up
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0     # create it
  url   = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  github_oidc_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}
```

Opposite `count` values, so exactly one is active. `local.github_oidc_arn` means "the
ARN, however we got it", and everything downstream uses that name and does not care.

### Terraform does NOT detect which case applies

`var.create_oidc_provider` is an assertion by a human, not a discovery. It was set
after checking by hand:

```bash
aws iam list-open-id-connect-providers      # empty in the management account
```

Getting it wrong fails loudly, not silently:

| Setting | Reality | Failure |
|---|---|---|
| `true` | one exists | apply fails, `EntityAlreadyExists` |
| `false` | none exists | plan fails, the data source finds nothing |

There is no clean way to auto-detect, because a data source that finds nothing is an
**error** in Terraform, not a null you can test.

### Why not just `terraform import` an existing one

Because import means "I own this". A later `terraform destroy` on seed would then
delete a provider that other teams' pipelines authenticate through. They did nothing
wrong and their deploys stop. The `data` block reads it without claiming it.

---

## 16. `count` is a desired quantity, not a one-time switch

The mistake worth naming: **`count = 1` does not mean "create it now", and it is not
flipped to `0` after the first run.**

```
count = 1   ->  exactly one should exist. Terraform makes reality match.
count = 0   ->  none should exist. If one exists, TERRAFORM DELETES IT.
```

So flipping `create_oidc_provider` to `false` after the first apply does not mean
"skip". It plans:

```
# aws_iam_openid_connect_provider.github[0] will be destroyed
```

### What actually stops a duplicate on the second run

State, not `count`.

| Run | Code says | State says | Reality | Plan |
|---|---|---|---|---|
| first | 1 should exist | nothing | none | 1 to add |
| every later run | 1 should exist | exists, ARN recorded | confirmed present | No changes |

Terraform compares three things every time: code, state, reality. That is also why
verification is `terraform plan` and not an AWS CLI call — the CLI only sees the
third one.

The setting is decided **once per account**, before that account's first apply, and
then left alone. Each account has its own state file.

---

## 17. Which ARNs you can predict, and which you must look up

Worth knowing before hardcoding anything.

**Derived from inputs — safe to construct:**

```
arn:aws:iam::193027353132:oidc-provider/token.actions.githubusercontent.com
    └─┬─┘ └┬┘  └────┬────┘ └────┬─────┘ └──────────────┬──────────────────┘
   partition │   account    resource type       the URL, minus https://
           service
```

| Resource | ARN | Predictable |
|---|---|---|
| OIDC provider | `.../oidc-provider/<url>` | yes, from the URL |
| IAM role | `.../role/<name>` | yes, from the name |
| S3 bucket | `arn:aws:s3:::<name>` | yes, from the name |

**Generated by AWS — must be read from the API:**

| Resource | Example | Read with |
|---|---|---|
| Control Tower baseline | `.../baseline/17BSJV3IGJ2QSGA2` | `aws controltower list-baselines` |
| Enabled baseline | `.../enabledbaseline/XAFT1OVF9PI4SCQGR` | `aws controltower get-enabled-baseline` |
| Organizational root | `r-inc0` | `aws organizations list-roots` |
| AWS account id | `193027353132` | assigned at creation |

This is why the organization layer reads the root id from
`data.aws_organizations_organization.current.roots[0].id` instead of hardcoding
`r-inc0`, and why the baseline version was checked (**3.0**) rather than assumed
(a guess said 4.0).

### `local.partition`

```hcl
data "aws_partition" "current" {}
locals { partition = data.aws_partition.current.partition }
```

Value is `aws`. AWS runs three separate walled-off copies of itself and ARNs differ:
`aws`, `aws-cn` (China), `aws-us-gov` (GovCloud). Used as
`"arn:${local.partition}:iam::aws:policy/AdministratorAccess"`. For this project it
will always be `aws`; it costs one line and removes a hardcoded string.

---

## 18. How an IAM role is linked to a GitHub repo

There is no registration, no handshake, no GitHub App. **The link is a string
comparison** inside the role's trust policy.

Two separate questions, two separate places:

| | Where | Answers |
|---|---|---|
| `assume_role_policy` | on the role | WHO may become this role |
| attached policies | `aws_iam_role_policy_attachment` | WHAT they can do once in |

The repo name enters the config exactly once, in `variables.tf`, and is referenced
from there:

```
variables.tf   var.github_repository = "pallasaisrujan28/Enterprise-Agent-Framework-Infra"
                    |
iam.tf         locals { github_sub_any_branch = "repo:${var.github_repository}:ref:refs/heads/*" }
                    |
iam.tf         condition { variable = "...:sub", values = [local.github_sub_any_branch] }
                    |
iam.tf         resource "aws_iam_role" "bootstrap_plan" { assume_role_policy = <that JSON> }
```

`aws_iam_policy_document` is a **data source that only renders JSON**. It makes no
AWS call and creates nothing.

### Anatomy of the `sub` value

```
repo:pallasaisrujan28/Enterprise-Agent-Framework-Infra:ref:refs/heads/*
└──┘ └──────────────┘ └──────────────────────────────┘ └──┘ └────────┘└┘
 1          2                        3                   4       5     6
```

1. literal text, always present
2. the GitHub account
3. the repository
4. literal text meaning "a git ref follows"
5. git's namespace for branches (tags are `refs/tags/`)
6. our wildcard

Not a URL and not a file path. GitHub's identifier format, written by GitHub from
the real run and signed. A workflow cannot set it.

### Two roles, because the claim changes shape

| Trigger | `sub` | Role it can assume |
|---|---|---|
| push to `feature/x` | `...:ref:refs/heads/feature/x` | plan role, read-only |
| push to `main` | `...:ref:refs/heads/main` | plan role, read-only |
| job with `environment: bootstrap-apply` | `...:environment:bootstrap-apply` | apply role, admin |

A single role pinned to `refs/heads/main` cannot be assumed from a feature branch
**and cannot be assumed by a job that declares an environment**. The second half is
the trap: adding the approval gate is what breaks it, so the failure arrives exactly
when the control is added.

### The wildcard's position is the control

```
repo:owner/repo:ref:refs/heads/*     safe — can only match a branch
repo:owner/repo:*                    DANGEROUS — also matches :environment:<name>
repo:owner/*                          DANGEROUS — every repo you own
```

### Nothing routes by branch

There is no logic anywhere saying "if branch X then role Y". The workflow names the
role ARN explicitly:

```yaml
- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ vars.AWS_PLAN_ROLE_ARN }}
```

AWS only answers yes or no. A feature branch asking for the apply role reaches STS
and is refused, because its token's `sub` is not the environment form. The workflow
chooses what to ask for; AWS enforces whether it is allowed. Editing YAML cannot
bypass the second part.

---

## 19. GitHub Environments as the approval gate

An Environment is a named thing in repo settings that holds rules about deployments.

**Created by hand:**

```
Settings > Environments > New environment > bootstrap-apply
  Required reviewers:    at least one person
  Deployment branches:   Selected branches -> main
```

**Used by one line on the job:**

```yaml
jobs:
  apply:
    environment: bootstrap-apply      # this line rewrites the sub claim
    permissions:
      id-token: write
```

**What GitHub does:** the run pauses at that line and shows "waiting for approval".
No token is issued until someone clicks Approve. After approval the token's `sub`
becomes `repo:<owner>/<repo>:environment:bootstrap-apply`.

**Why it is stronger than branch protection.** Branch protection proves code was
reviewed and merged. It does not prove anyone approved *this deployment*. GitHub
will not write an environment claim unless the job really ran in that Environment,
so AWS seeing that string is evidence a human approved this run.

**The honest limit.** AWS can only check the Environment's *name*. It cannot check
that reviewers are configured. An Environment with no reviewers still produces the
same claim and apply proceeds unattended. That half is yours to enforce.

**Correction to an earlier claim.** A comment in `variables.tf` once said Terraform
cannot create the Environment. Wrong — the AWS provider cannot, but the GitHub
provider's `github_repository_environment` can, including reviewers and branch
policy. Not used because it needs a GitHub token with repo admin rights, which is a
new long-lived secret to store and rotate. Doing it by hand once is the smaller cost,
but it is a choice, not a limitation.

---

## 20. Validating IAM and SCP policies

**Reading policy HCL by eye does not work.** Three bugs got in that way, and each
one would have denied *nothing* while reading as a guardrail:

| Written | Problem |
|---|---|
| `bedrock:Converse` | an API name, not an IAM action |
| `s3:DeleteAccountPublicAccessBlock` | no such action; removal is a `Put` with all flags false |
| `accessanalyzer:DeleteAnalyzer` | service prefix needs the hyphen: `access-analyzer` |

An unknown action inside a `Deny` denies nothing. There is no error at apply time and
no error at request time. The guardrail is simply absent.

```bash
aws accessanalyzer validate-policy \
  --policy-document file://policy.json \
  --policy-type SERVICE_CONTROL_POLICY
```

`--policy-type` matters. Validated as an identity policy, the wrong rules apply.

### Render from a plan, not from `terraform console`

`terraform console` reads data sources out of state. With no state yet it answers
`(known after apply)`. A plan actually resolves the data source:

```bash
terraform plan -no-color -out=p.tfplan
terraform show -json p.tfplan     # pull .content off the policy resource
```

### A clean result is only meaningful if the check can fail

Re-inject the three known-bad actions into a throwaway copy and confirm Access
Analyzer still rejects them. Without that, a validator that quietly stopped working
looks identical to a clean policy.

### SCP limits worth knowing before designing

- **Five policies maximum per target.** Control Tower already uses part of that
  budget, so five of ours would fail at attach time. Five concerns became five
  *statements* in one policy.
- 5,120 character limit on the policy body. Ours renders at 1,474.

---

## 21. Two checks that lied

Both reported confidently while measuring the wrong thing. This is the failure mode
to watch for.

**A broken-link check reported 27 failures.** It parsed block-style YAML aliases
while the generator writes them inline. The real number was 5.

**A plan check reported "no changes" when the plan said 6 to add.** Terraform
colorizes output even when stdout is a file, so the line was
`\033[1mPlan:\033[0m 6 to add` and `grep '^Plan:'` never matched. Fix:

```bash
terraform plan -no-color ...
```

and make the check **fail** when it cannot find what it is looking for, rather than
falling back to a cheerful default:

```bash
if ! grep -E '^Plan: ' plan.txt; then
  echo "no Plan: line found - do not trust this run" >&2
  exit 1
fi
```

A check that cannot fail is not a check.

---

## 22. Local helper scripts

`.local/` is gitignored scratch space. Nothing in the pipeline uses it, and some of
it reads credentials from a file outside the repo.

| File | Purpose |
|---|---|
| `root-env.sh` | loads management-account keys, **refuses to run unless the account is `193027353132`** |
| `render-scp.sh` | plans, then extracts the rendered SCP JSON |
| `extract_scp.py` | pulls the policy body out of `terraform show -json` |
| `validate-scp.sh` | runs Access Analyzer, exits non-zero on findings |
| `negative-control.sh` | proves the validator can still fail |

Three reasons these are files rather than typed commands:

1. **Repeatability.** The same command each time, so a difference in output is a real
   difference.
2. **The credential guard runs every time.** An empty `AWS_ACCESS_KEY_ID_*` does not
   error — the CLI falls through to another credential source and answers
   successfully for the *wrong account*. That already happened once.
3. **Long commands break when inlined.** Python inside a shell heredoc produced a
   `SyntaxError` from nested quotes. Write it to a file instead.

If a script earns permanence it moves out of `.local/` into a committed `scripts/`
directory with a Makefile target. Nothing here has yet.

---

## 23. The OIDC subject format changed, and every example is now wrong

The first pipeline run failed with:

```
Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity
```

That message names no condition and no claim. It is the same for a wrong repo, a
wrong branch, a wrong audience, and a wrong subject format.

### The cause

Every published example, and the first version of `iam.tf`, used:

```
repo:<owner>/<repo>:ref:refs/heads/*
```

GitHub sends something else. The real claim, measured:

```
repo:pallasaisrujan28@194785418/Enterprise-Agent-Framework-Infra@1324052608:ref:refs/heads/feature/bootstrap-organization
```

Numeric ids are embedded. Repositories created after **2026-07-15** use this
immutable default format. It does not apply to GitHub Enterprise Server.

- [GitHub changelog](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/)
- [Microsoft's migration guidance](https://learn.microsoft.com/en-gb/entra/workload-id/workload-identities-github-immutable-subjects)

It is a security improvement, not an annoyance. The ids are assigned once and never
reused, so renaming, transferring, or deleting and recreating a repository does not
carry the old trust across. Under the name-based format, a deleted repository's name
could be claimed by someone else and inherit its AWS access.

### The API lies about it

```bash
gh api repos/OWNER/REPO/actions/oidc/customization/sub
```

returned:

```json
{
  "use_default": true,
  "use_immutable_subject": false,
  "sub_claim_prefix": "repo:pallasaisrujan28@194785418/Enterprise-Agent-Framework-Infra@1324052608"
}
```

`use_immutable_subject: false`, and the token uses the immutable form regardless. So
**the token is the only authoritative source.**

### How to read the real claim

A temporary `workflow_dispatch` workflow. Decode the payload, print an allow-list of
fields, and **never print the token** — the payload is not a credential, the token is,
and a build log in a public repository is readable by anyone.

```yaml
permissions:
  id-token: write
steps:
  - uses: actions/github-script@v7
    with:
      script: |
        const token = await core.getIDToken('sts.amazonaws.com')
        const payload = JSON.parse(
          Buffer.from(token.split('.')[1], 'base64url').toString('utf8')
        )
        for (const key of ['iss', 'aud', 'sub', 'repository', 'repository_id',
                           'repository_owner_id', 'ref', 'environment']) {
          core.info(`${key} = ${payload[key] ?? '(absent)'}`)
        }
```

Delete it once the trust policy is confirmed. Ten minutes of measuring beat an
unknown number of rounds of guessing at a string format.

### Why not condition on `repository_id` instead

The token also carries `repository_id` and `repository_owner_id` as their own claims,
which would avoid parsing a composite string. Not used, because the sources disagree:

- GitHub's AWS guide says custom OIDC claims are unsupported in AWS and recommends
  evaluating `token.actions.githubusercontent.com:sub`.
- Later reporting says AWS STS added provider-specific GitHub claims as condition keys.

The cost of being wrong is asymmetric. **An unrecognised condition key does not
error** — the statement simply never matches, so every run is denied and it presents
as a trust bug rather than an unsupported feature. `sub` is agreed by both sources and
measured working.

Revisit only with a verified assume-role call, never with a documentation link.

### Assemble it, do not paste it

```hcl
locals {
  repo_owner = split("/", var.github_repository)[0]
  repo_name  = split("/", var.github_repository)[1]

  github_sub_prefix = "repo:${local.repo_owner}@${var.github_repository_owner_id}/${local.repo_name}@${var.github_repository_id}"

  github_sub_any_branch        = "${local.github_sub_prefix}:ref:refs/heads/*"
  github_sub_apply_environment = "${local.github_sub_prefix}:environment:${var.github_apply_environment}"
}
```

`var.github_repository` stays the single place the repository is named. The ids come
from validated numeric variables:

```bash
gh api repos/OWNER/REPO --jq '{id: .id, owner_id: .owner.id}'
```

### Also learned in that run

**A new branch does not trigger path-filtered workflows.** `plan.yml` has
`paths: ["bootstrap/**", ...]` and did not run on the first push of a new branch. It
ran on the second push. If a workflow mysteriously does not start on a branch you just
created, this is why.

**tflint earns its place immediately.** It caught two dead declarations on the first
run: a `terraform_remote_state` read of the seed layer that nothing consumed, and an
unused `local.account_id`. Removing the first made `var.state_bucket` unused too,
which had been passed by both workflows, the Makefile and the README.

**tflint is not in homebrew-core.** `brew install tflint` fails and suggests unrelated
formulae. It needs the tap:

```bash
brew install terraform-linters/tap/tflint
```

CI installs it through `terraform-linters/setup-tflint`, so a green CI run does not
mean the local `make lint` target works.

---

## 24. Ideas parked for later

**Account creation through a request workflow.** A Jira board or form feeding an
approval that triggers the account-creation pipeline, rather than a hand-run
`workflow_dispatch`. Sensible once accounts are created often enough to justify it.
The Terraform underneath does not change — only what triggers it.

**ArgoCD or a similar GitOps controller.** Relevant if Kubernetes arrives. Terraform
would still own the AWS layer.
