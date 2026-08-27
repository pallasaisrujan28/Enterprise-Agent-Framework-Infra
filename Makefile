SHELL := /bin/bash
.PHONY: fmt fmt-check lint validate check install-hooks

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

# ── Combined (mirrors CI exactly) ─────────────────────────────────────────────

validate-yaml:
	@for f in .github/workflows/*.yml; do 	  python3 -c "import yaml,sys; yaml.safe_load(open('$$f').read())" 2>&1 	    && echo "✓ $$f" 	    || { echo "✗ $$f — invalid YAML"; exit 1; }; 	done

check: fmt-check lint validate-yaml

# ── Git hooks ─────────────────────────────────────────────────────────────────

install-hooks:
	git config core.hooksPath .githooks
	@echo "Pre-push hook installed. 'make fmt-check && make lint' runs before every push."
	@echo "Run 'make fmt' to auto-fix formatting before committing."
