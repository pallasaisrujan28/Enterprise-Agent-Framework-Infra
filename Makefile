SHELL := /bin/bash
.PHONY: fmt fmt-check lint validate check install-hooks test iam-inventory iam-orphans

# Layers whose state may contain IAM roles. Used by the IAM inventory and orphan
# checks. Add new layers here as they are created — a layer missing from this list
# would make its roles look like orphans.
IAM_LAYERS := accounts/dev accounts/prod workloads/eaf/dev/platform \
              workloads/eaf/dev/cluster-addons workloads/eaf/dev/apps

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

validate:
	@set -euo pipefail; \
	for dir in $$(find . -name '*.tf' -not -path './.git/*' -exec dirname {} \; | sort -u); do \
	  echo "validating $$dir ..."; \
	  terraform -chdir=$$dir init -backend=false -input=false -no-color -upgrade > /dev/null; \
	  terraform -chdir=$$dir validate -no-color; \
	done

# ── Module unit tests ─────────────────────────────────────────────────────────
# `terraform test` with command = plan throughout. No AWS credentials, no
# resources created, a few seconds. This is the fast half of the local loop: the
# feedback channel that replaces pushing a branch and waiting twenty minutes.

test:
	@set -euo pipefail; \
	found=0; \
	for dir in $$(find modules -type d -name tests -not -path '*/.terraform/*' | sort); do \
	  mod=$$(dirname $$dir); \
	  echo "==> testing $$mod"; \
	  terraform -chdir=$$mod init -backend=false -input=false -no-color > /dev/null; \
	  terraform -chdir=$$mod test -no-color; \
	  found=1; \
	done; \
	if [ "$$found" = "0" ]; then echo "no module tests found"; fi

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

# ── Combined (mirrors CI exactly) ─────────────────────────────────────────────

check: fmt-check lint test

# ── Git hooks ─────────────────────────────────────────────────────────────────

install-hooks:
	git config core.hooksPath .githooks
	@echo "Pre-push hook installed. 'make fmt-check && make lint' runs before every push."
	@echo "Run 'make fmt' to auto-fix formatting before committing."
