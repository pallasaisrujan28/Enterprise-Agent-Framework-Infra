# Claude Code — Project Instructions

This file is read by Claude Code at the start of every session. It contains
decisions, constraints, and reasoning that must be respected when making changes
to this repository.

---

## Repository purpose

Terraform for the AWS accounts and guardrails the Enterprise Agent Framework
platform runs on. Application code lives in a separate repository.

Every AWS resource is created through GitHub Actions + Terraform. Nothing is
created directly from a terminal or script.

---

## Decision-making rule: security changes require full-picture thinking

### The rule

Before fixing any error that involves a security control (SCP, IAM policy,
permissions boundary, trust policy, bucket policy, security group), answer
these two questions first:

1. **Why does the control exist?** What attack or mistake was it written to prevent?
2. **What does removing or relaxing it leave open?** Who could exploit the gap,
   through which path, and with what consequence?

Only proceed with the change after both questions have clear answers.

### Why this rule exists — the incident that produced it

During per-account baseline work, `terraform apply` failed with:

```
AccessDenied: not authorized to perform s3:PutAccountPublicAccessBlock
because no identity-based policy allows the controltower action
```

The immediate fix that was proposed: remove Statement 4 from the guardrail SCP
(`DenyS3PublicAccessWeakening`), because the SCP was blocking a call we needed
to make.

That fix was technically correct — it would have unblocked the apply. But it
was strategically wrong. Removing Statement 4 would have allowed anyone with
pipeline access to later call `s3:PutAccountPublicAccessBlock` with all flags
set to `false`, disabling the account-level public access block and making
S3 data exposure possible.

The right fix — reached by asking "what does removing this leave open?" —
was to keep the SCP unchanged and instead remove the redundant Terraform
resource. AWS enables the S3 public access block by default for all accounts
created after April 2023. The Terraform resource was trying to set something
that was already set. The SCP protects it from being unset. Both protections
remain intact.

### The pattern to avoid

```
Error hits  →  find the thing blocking the action  →  remove it  →  error gone
```

This pattern fixes the symptom. It does not ask whether the thing that was
blocking the action was supposed to be blocking it.

### The pattern to follow

```
Error hits
  ↓
Understand WHY the blocking control exists
  ↓
Ask: does removing or relaxing this control leave anything open?
  ↓
If YES: find a fix that does not touch the control
If NO:  the control was over-broad; fix it carefully with the gap documented
```

### Applied to this project specifically

**SCPs in `bootstrap/org-structure/scps.tf`** are guardrails on the Workloads
OU. They apply to every principal in every member account — including pipeline
roles. Before changing an SCP:
- State what attack the statement prevents
- State what the change allows that was previously blocked
- Confirm that what is newly allowed cannot be used to undo the original protection

**IAM policies in `bootstrap/seed/iam.tf`** define what the pipeline roles can do.
Before adding a permission:
- State why the permission is needed
- Confirm it is the minimum scope (specific action + specific resource)
- Confirm the permission cannot be used to escalate beyond the role's intended function

**Permissions boundaries in `modules/account-baseline/main.tf`** cap workload CI
roles. Before changing the boundary:
- Confirm the new permission is needed for a specific workload operation
- Confirm it does not allow the role to remove its own boundary
- Confirm it does not allow the role to create unconstrained child roles

---

## Other standing decisions

### No resources created from the terminal

Every AWS resource is created by Terraform through a GitHub Actions workflow.
The terminal is for triggering workflows (`gh workflow run`), reading state
(`aws sts get-caller-identity`), and verifying results. Not for creating or
modifying resources.

Exceptions that are acceptable: one-time reads (`aws iam get-role`),
verification checks (`aws organizations list-accounts`), and diagnosing errors
in CI runs (`gh run view --log`).

### Every feature on its own branch

New features and fixes go on dedicated branches. One PR per logical change.
Branches that have merged are deleted.

### Account names and emails are permanent

AWS account names and root emails cannot be changed after creation. The
`accounts/register.yaml` file and SSM parameters are the single source of
truth. Do not suggest changing either.

### apply.yml push trigger is intentionally disabled

The `apply.yml` workflow has its push-to-main trigger commented out until
the per-account baseline layer is fully built and tested. Do not re-enable
it without verifying the accounts/dev and accounts/prod layers are complete.
