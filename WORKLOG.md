# Work log

What was changed, why, what was verified, and the commands to reproduce each check.

Exists because the reasoning was previously spread across commit messages and chat, and
neither is somewhere you can look things up later. `git log` remains the authoritative
record of *what* changed; this file records the *checks* and the *decisions*, including
the ones that turned out wrong.

Newest entry first.

---

## 2026-08-14 — Account vending: register, multi-OU, request workflow

### Decisions

**The input layer is a file, not a pipeline variable.** `accounts/register.yaml` decides
which accounts exist and which OU each lives in.

The reason is not tidiness. When the account set arrived as a pipeline input, a run
supplying only a NEW account would make Terraform plan to **destroy** every account not
mentioned in that run. That makes an account-vending pipeline a one-shot script.
`prevent_destroy` turns the mistake into an error rather than a disaster, but a file that
accumulates is what stops it arising.

**Emails go to SSM, never to git.** An account's email becomes its root user and only
recovery address, and AWS has no API to change it. It is written once by the
request-account workflow to `/eaf/accounts/<NAME>/email` and only ever read afterwards.
The provider marks parameter values sensitive, so it stays out of plan output and out of
the uploaded plan artifact.

**OUs come from the register.** `ou_name` was a single variable, so the repository served
exactly one project. Every distinct `ou:` value now becomes an OU, created if absent.

**`bootstrap/organization` renamed to `bootstrap/org-structure`.** The old name sat next
to the AWS service called Organizations and read as if the directory *were* an OU. It is
a directory of Terraform with its own state file. An OU is a folder inside AWS.

**No inventory file, no DynamoDB registry.** Argued for one, then against it. The
queryable index already exists: the tags on each account. A generated file or a table
would be a third copy of the truth that can drift from the register and from state. The
`account_register` output is the human-readable join.

### Corrected from earlier in the same session

**GuardDuty and Security Hub org-wide: dropped.** Verified there is no delegated
administrator for either service anywhere in this organization:

```bash
aws guardduty list-organization-admin-accounts     # AdminAccounts: []
aws securityhub list-organization-admin-accounts   # AdminAccounts: []
aws organizations list-delegated-administrators    # DelegatedAdministrators: []
```

So enabling either at organization level would switch it on across **all 25 accounts**,
including `aston-martin`, `Cupra.DRUK`, `mlops-prod`, and bill each one. Not ours to
decide. If we want threat detection it goes in the per-account baseline, inside our two
accounts only.

The earlier argument for org-wide — one configuration cannot drift — only holds when the
organization is yours.

**Also out:** CloudTrail and AWS Config, because Control Tower already enables both on
enrolled OUs and sends CloudTrail to Log Archive `317904778871`. And networking, because
a VPC costs money hourly, Bedrock does not need one, and a Transit Gateway is painful to
unpick.

### Protecting other teams

`bootstrap/org-structure/variables.tf` carries `protected_ou_names`, read from the live
organization rather than invented:

```bash
ROOT=$(aws organizations list-roots --query 'Roots[0].Id' --output text)
aws organizations list-organizational-units-for-parent --parent-id "$ROOT" \
  --query 'OrganizationalUnits[].Name' --output text
# Sandbox  Security  MLOps  Apps  Sprint BE  Clients
```

A `check` block fails the plan if the register names one of those. AWS would reject a
duplicate OU name anyway, but that failure reads as a naming clash rather than "you tried
to take over another team's governance".

The SCP attaches with `for_each` over **OUs this repository created**, never the root. An
SCP on the root would apply to all 25 accounts.

### Verified

```bash
# the rename was free - only seed had state, so nothing to migrate
aws s3 ls s3://eaf-bootstrap-tfstate-193027353132/bootstrap/ --recursive
# -> bootstrap/seed/terraform.tfstate only

terraform fmt -check -recursive
terraform -chdir=bootstrap/seed validate           # valid
terraform -chdir=bootstrap/org-structure validate  # valid
actionlint                                         # clean
```

The register script was tested against four cases before it ever ran in CI:

```bash
python3 scripts/register_add.py --register /tmp/t.yaml --name EAF-DEV ...     # rejects duplicate
python3 scripts/register_add.py --register /tmp/t.yaml --environment banana   # rejects bad environment
python3 scripts/register_add.py --register /tmp/t.yaml --name "bad name!"     # rejects bad name
python3 scripts/register_add.py --register /tmp/t.yaml --name EAF-SANDBOX ... # adds, header preserved
```

### Not done

- The request role in `bootstrap/seed/iam.tf` is written but **not applied**. It goes
  through the pipeline, not a local apply.
- `bootstrap/org-structure` has never been applied. No OU, no SCP, no accounts exist.
- The per-account baseline does not exist yet: permissions boundary, CI role, budget
  alert, S3 public access block, in-account GuardDuty.

---

## 2026-08-13 — Pipelines, and the OIDC subject that broke them

### What was applied to AWS

Three `terraform apply` runs against `193027353132`, all on the seed layer:

| Change | Result |
|---|---|
| Split one pipeline role into plan and apply | 3 added, 1 changed |
| Match GitHub's immutable OIDC subject format | 0 added, 2 changed |
| Rename the Environment `bootstrap-apply` to `management` | 0 added, 1 changed |

Nothing was destroyed. No accounts, OU or SCP were created — that layer has never run.

### The failure worth remembering

```
Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity
```

That message names no claim and no condition. Identical for a wrong repo, wrong branch,
wrong audience, or wrong subject format.

Cause: GitHub changed the default subject format. Repositories created after 2026-07-15
embed immutable numeric ids. Measured from a real token rather than guessed:

```
sub = repo:pallasaisrujan28@194785418/Enterprise-Agent-Framework-Infra@1324052608:ref:refs/heads/feature/bootstrap-organization
```

The customization API is misleading here — it reports `use_immutable_subject: false`
while the token uses the immutable form anyway. **The token is the only authoritative
source.** Full write-up in `TERRAFORM-NOTES.md` section 23.

### Verified

```bash
# both auth paths, measured not assumed
# plan role:  plan seed job reported No changes against the real account
# apply role: a temporary workflow assumed it and printed
#   Arn = arn:aws:sts::193027353132:assumed-role/eaf-bootstrap-pipeline-role/...

aws accessanalyzer validate-policy --policy-type SERVICE_CONTROL_POLICY \
  --policy-document file://scp-rendered.json
# 5 statements, 1474 chars, 0 findings
# negative control: the three known-bad actions are still rejected
```

### Two checks that lied

A broken-link check reported 27 failures while parsing the wrong YAML style; the real
number was 5. A plan check reported "no changes" while the plan said 6 to add, because
Terraform colorizes into a pipe and `grep '^Plan:'` never matched.

Both now fail loudly when they cannot find what they are looking for, rather than falling
back to a reassuring default. A check that cannot fail is not a check.
