SHELL := /bin/bash
.PHONY: fmt fmt-check lint validate check install-hooks test iam-inventory iam-orphans topology \
        storage-orphans teardown-check test-scripts

# Layers whose state may contain IAM roles. Used by the IAM inventory and orphan
# checks. ADD NEW LAYERS HERE AS THEY ARE CREATED — a layer missing from this list
# makes its roles look like orphans, and the orphan check deliberately refuses to
# report at all rather than name a managed role as unmanaged.
#
# workloads/eaf/dev/{platform,cluster-addons,apps} are appended at design Steps 3
# and 4, when those directories exist. They are not listed pre-emptively because
# the check treats a missing directory as an error, not as an empty layer.
IAM_LAYERS := accounts/dev accounts/prod workloads/dev/registry workloads/dev/platform workloads/dev/cluster-addons workloads/dev/apps

# ── Formatting ─────────────────────────────────────────────────────────────────

# Auto-fix all formatting in place. Run before committing.
fmt:
	terraform fmt -recursive

# Check-only (used in CI). Exits non-zero if anything would be reformatted.
fmt-check:
	terraform fmt -check -recursive -diff

# ── Linting ────────────────────────────────────────────────────────────────────

lint:
	tflint --init --recursive --format compact

# ── Validation ─────────────────────────────────────────────────────────────────
# Validates every directory that contains .tf files. Mirrors the CI static job.

# NOTE: no `-upgrade` on the init below, deliberately.
#
# With it, running `make validate` on a workstation REWRITES every committed
# .terraform.lock.hcl with hashes for the local platform only. A macOS-generated lock
# file omits linux_amd64, and CI then fails with "provider does not have a package
# available for your current platform" — which looks like a registry outage and is not.
#
# Without it, init uses the committed lock file when there is one. To deliberately move
# a provider version, do it for every platform that runs it:
#
#   terraform providers lock \
#     -platform=darwin_arm64 -platform=darwin_amd64 -platform=linux_amd64
validate:
	@set -euo pipefail; \
	for dir in $$(find . -name '*.tf' -not -path './.git/*' -exec dirname {} \; | sort -u); do \
	  echo "validating $$dir ..."; \
	  terraform -chdir=$$dir init -backend=false -input=false -no-color > /dev/null; \
	  terraform -chdir=$$dir validate -no-color; \
	done

# ── Module unit tests ─────────────────────────────────────────────────────────
# `terraform test` with command = plan throughout. No AWS credentials, no
# resources created, a few seconds. This is the fast half of the local loop: the
# feedback channel that replaces pushing a branch and waiting twenty minutes.

# RUNS EVERY MODULE, THEN FAILS — it does not stop at the first broken one.
#
# The previous version relied on `set -e` to abort the loop, so a run with three failing
# modules reported one. That is tolerable on a laptop, where you re-run in a second, and
# expensive in CI, where each iteration is a push and a wait. Fail-fast turns one bad commit
# into three round trips.
#
# The exit code is captured explicitly rather than with `|| true`, and a non-empty failure
# list exits non-zero. Property 4 forbids a step that cannot fail; this aggregates failures,
# it does not swallow them.
# THE CREDENTIAL CHAIN IS SEVERED, so a local run and a CI run see the same thing.
#
# These tests are supposed to be offline. Proving that by unsetting AWS_* environment
# variables is not enough: the credential chain continues to ~/.aws/credentials, which
# exists on a laptop and does not exist on a runner. modules/iam-role passed here for weeks
# on a developer's local profile and failed the moment CI ran it — 0 passed, 26 skipped,
# "No valid credential sources found".
#
# So the environment is emptied AND the shared config and credentials files are pointed at
# /dev/null, and HOME is moved aside so nothing is discovered under it. AWS_EC2_METADATA_
# DISABLED closes the last path, the instance metadata endpoint, which is reachable on an
# EC2 runner and would otherwise be another way for local and CI to disagree.
#
# If a test needs credentials, it is not a unit test, and this makes that a failure rather
# than a difference of laptop.
TEST_ENV := env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
              -u AWS_PROFILE -u AWS_REGION -u AWS_DEFAULT_REGION \
              HOME=/tmp/eaf-test-nohome \
              AWS_CONFIG_FILE=/dev/null \
              AWS_SHARED_CREDENTIALS_FILE=/dev/null \
              AWS_EC2_METADATA_DISABLED=true

test:
	@mkdir -p /tmp/eaf-test-nohome; \
	set -uo pipefail; \
	found=0; failed=""; \
	for dir in $$(find modules -type d -name tests -not -path '*/.terraform/*' | sort); do \
	  mod=$$(dirname $$dir); \
	  echo "==> testing $$mod"; \
	  $(TEST_ENV) terraform -chdir=$$mod init -backend=false -input=false -no-color > /dev/null || { failed="$$failed $$mod(init)"; continue; }; \
	  $(TEST_ENV) terraform -chdir=$$mod test -no-color; \
	  if [ $$? -ne 0 ]; then failed="$$failed $$mod"; fi; \
	  found=1; \
	done; \
	if [ "$$found" = "0" ]; then echo "no module tests found"; fi; \
	if [ -n "$$failed" ]; then \
	  echo ""; echo "FAILED modules:$$failed"; exit 1; \
	fi

# ── IAM inventory and orphan detection ────────────────────────────────────────
#
# The mechanical answer to "we created roles to fix issues and lost track of them".
#
#   iam-inventory  what Terraform manages, generated from state
#   iam-orphans    what exists in the account that Terraform does NOT manage
#
# iam-orphans is the one that prevents recurrence, and it runs in the pipeline
# after each apply. Both need credentials for the target account; iam-orphans also
# needs state access for every layer in IAM_LAYERS.

iam-inventory:
	@python3 scripts/iam_inventory.py inventory $(IAM_LAYERS)

iam-orphans:
	@python3 scripts/iam_inventory.py orphans $(IAM_LAYERS)

# ── Untracked-resource detection beyond IAM ───────────────────────────────────
#
# The teardown proved this is needed. `terraform destroy` reported complete
# success — 82 resources, zero errors — and left behind an 8 GiB EBS volume that
# Terraform had never heard of: the EBS CSI driver provisioned it for Langfuse's
# Postgres PVC, so it was created through the Kubernetes API, not by Terraform.
#
# A resource created by a controller inside the cluster is invisible to the
# configuration that created the cluster. That is the storage version of the
# searxng orphan, and it survives a teardown that looks clean.
#
# Cluster-provisioned volumes are identifiable: the CSI driver tags them with
# kubernetes.io/created-for/pvc/name and ebs.csi.aws.com/cluster-name.
# ── Topology ───────────────────────────────────────────────────────────────────
# Draw the LIVE AWS topology as Mermaid, which renders in VS Code and on GitHub
# without a plugin or a rendering step.
#
# Read from the AWS API rather than from state or configuration, deliberately: a
# diagram built from configuration shows what should exist. This one shows what does.
# Those differ exactly when it matters.
#
# Read-only. Every call is a describe or a list.
topology:
	@python3 scripts/aws_topology.py -o docs/topology.md

storage-orphans:
	@python3 scripts/iam_inventory.py storage-orphans

# What is still costing money in the region, and what a teardown left behind.
#
# Run it AFTER a teardown to confirm nothing leaked: a load balancer, a detached
# volume or an unassociated elastic IP with nothing tracking it all keep billing.
# Read-only.
teardown-check:
	@python3 scripts/teardown_guard.py --sweep --region $${AWS_REGION:-eu-west-2}

# The guard's own tests. Kept separate from `test`, which is terraform test, because
# this is python and needs no AWS credentials or provider mocks.
test-scripts:
	@python3 scripts/tests/test_teardown_guard.py

# ── Combined (mirrors CI exactly) ─────────────────────────────────────────────

check: fmt-check lint test test-scripts

# ── Git hooks ─────────────────────────────────────────────────────────────────

install-hooks:
	git config core.hooksPath .githooks
	@echo "Pre-push hook installed. 'make fmt-check && make lint' runs before every push."
	@echo "Run 'make fmt' to auto-fix formatting before committing."
