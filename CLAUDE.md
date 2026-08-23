# Claude Code — Project Instructions

This file is read by Claude Code at the start of every session. It governs how
decisions are made across the entire Enterprise Agent Framework project — not
just this infrastructure repository.

The end goal is a production-grade agentic AI system comparable to OpenClaw or
Manus: agents that can reason, take actions across systems, maintain state, and
operate autonomously within defined boundaries. Every technical decision made
today either enables or constrains that goal.

---

## The core decision-making rule: understand before you change

This is the most important rule in this file. It applies everywhere — to
Terraform, to agent architecture, to IAM policies, to API design, to prompts.

### When you hit a technical blocker

**Never remove a constraint without understanding why it exists.**

The question to ask first is not "how do I get past this?" It is:

> "Why is this constraint here, and what does removing it leave open?"

A constraint that blocks you from doing something useful was probably put there
to block someone from doing something harmful — and the constraint cannot tell
the difference between you and the someone.

### The two-question test

Before changing any constraint — a security policy, a permission, a rate limit,
a validation rule, an API restriction, an agent boundary:

1. **Why does this constraint exist?**
   What failure, attack, or mistake was it written to prevent?

2. **What does removing or relaxing it leave open?**
   Who can now do what they could not do before? Through what path?
   With what consequence?

If the answer to question 2 is "nothing material" — the constraint was
over-broad, or the risk it was protecting against no longer applies — then
changing it is correct. Document the reasoning.

If the answer to question 2 reveals a real gap — stop. Find a solution that
does not touch the constraint.

### The incident that produced this rule (recorded so it is not forgotten)

During per-account baseline work, `terraform apply` failed:

```
AccessDenied: not authorized to perform s3:PutAccountPublicAccessBlock
denied by service control policy
```

The immediate fix proposed: remove the SCP statement that was blocking the
call. Reasoning: the SCP was blocking a call we needed to make; AWS enables
this setting by default for new accounts anyway.

The question that was NOT asked first: what does removing this statement
allow that was previously blocked?

The answer: it would allow anyone with pipeline access to later call
`s3:PutAccountPublicAccessBlock` with all flags set to false — disabling the
account-level public access block and making S3 data exposure possible.

The right fix: keep the SCP unchanged. Remove the Terraform resource instead.
The setting was already enabled by AWS default. The resource was redundant.
Both protections remain intact.

Removing the SCP would have fixed the error. It would also have removed a
security control without noticing.

---

## Project-wide principles

### 1. Agents operate within defined boundaries — do not expand them to fix errors

Agents will hit limits: tool call failures, permission denials, context
exhaustion, rate limits, memory constraints. The instinct is to expand the
boundary so the agent can proceed.

Before expanding any agent boundary, apply the two-question test:
- Why is this limit here?
- What can the agent now do that it could not do before?

An agent with unbounded tool access is not more capable — it is unpredictable.
The boundaries are what make the system auditable and safe to run autonomously.

### 2. Principle of least privilege applies to agents, not just infrastructure

Every agent, tool, and pipeline role should have the minimum permissions needed
for its specific task. This is not a security formality — it is what makes a
system debuggable and explainable.

When an agent can only do a small number of things, a failure has a small blast
radius. When an agent can do anything, a failure has an unbounded blast radius.

This applies to:
- IAM roles and permissions boundaries for infrastructure pipelines
- Tool access granted to agents
- Data access patterns for agent memory
- API scopes for external service integrations

### 3. Every action taken by an agent must be traceable

An agent that takes an action and leaves no record is an agent that cannot be
audited, debugged, or trusted. This means:

- Infrastructure changes go through Git — the commit history is the audit trail
- Agent actions are logged with enough context to reconstruct why they happened
- Approvals are recorded — who approved what, when, and on what plan
- Emails, account names, and decisions that cannot be changed are stored
  permanently (SSM, state files) — not in ephemeral memory

### 4. Human approval gates are not optional for irreversible actions

Some actions cannot be undone: creating an AWS account (90-day closure),
sending an email, publishing to a production endpoint, deleting data.

These actions must pause for a human to read exactly what will happen and
explicitly approve it. The plan the human reads must be the plan that executes
— not a re-generated plan made afterwards.

This applies equally to infrastructure applies, agent tool calls that modify
production data, and any operation whose consequence outlasts the session.

### 5. Do not fix the symptom — understand the root cause

When something fails, the error message describes the symptom. The root cause
is usually one or two levels deeper.

Pattern to avoid:
```
Error: X is denied  →  remove the rule denying X  →  error gone
```

Pattern to follow:
```
Error: X is denied
  ↓
Why was X denied? What rule, and why does that rule exist?
  ↓
Is the rule correct but over-broad? Or is the operation genuinely wrong?
  ↓
Fix the operation if it is wrong.
Fix the rule narrowly if it is over-broad, documenting the reasoning.
```

### 6. Data residency is a product requirement, not a preference

The initial use case for this platform is answering questions about UK statute.
Inference and data must stay in the UK (eu-west-2). This is not a configuration
choice — it is a product property.

When adding services, integrations, or agent capabilities:
- Verify they support eu-west-2
- Verify they do not route data to other regions as a fallback
- The Bedrock inference profile restriction in the SCP exists because
  cross-region routing happened silently in practice (6 out of 6 calls went
  to eu-north-1 despite being made in eu-west-2)

### 7. No long-lived credentials anywhere in the system

IAM users, access keys, static API tokens, and hardcoded secrets are
permanently forbidden. Everything authenticates with temporary credentials
(OIDC, role assumption, short-lived tokens).

This applies to agents as well as infrastructure pipelines. An agent that
holds a long-lived credential is a credential waiting to leak.

### 8. Infrastructure changes go through the pipeline — not the terminal

No AWS resource is created from a terminal command. Every change goes through
Git, a PR, a plan, and an approval. The pipeline is the only path to production.

The terminal is for: triggering workflows, reading current state, verifying
results after a pipeline run. Not for creating, modifying, or deleting resources.

---

## Infrastructure-specific decisions

### Every feature on its own branch

One branch per logical change. PRs are the unit of review. Branches that have
merged are deleted.

### Account names and emails are permanent

AWS account names and root emails cannot be changed after creation. The
`accounts/register.yaml` file and SSM parameters at `/eaf/accounts/*/email`
are the single source of truth. Never suggest changing either.

### apply.yml push trigger is intentionally disabled

Disabled until the per-account baseline layer (`accounts/dev`, `accounts/prod`)
is fully built, tested, and applied. Re-enabling it before that is complete
would apply account-level changes automatically without the baseline being in
place.

### SCP changes require the two-question test — no exceptions

The guardrail SCP in `bootstrap/org-structure/scps.tf` applies to every
principal in every member account, including pipeline roles. A change that
looks like a minor permission adjustment can remove a protection that applies
across the entire OU.

Before any SCP change:
1. State what the statement being changed currently prevents
2. State what the change now allows
3. Confirm that what is newly allowed cannot be used to circumvent the
   original protection

---

## How to use this file

When Claude Code encounters a technical error or a decision point, it should
check this file before proposing a solution. If the proposed solution would
touch a constraint — relax a permission, remove a rule, expand a boundary —
the two-question test must be applied and the answers written explicitly before
proceeding.

The user will ask questions. Those questions are the right ones. The answers
to "why?" and "what does this leave open?" are more important than the speed
of fixing the error.
