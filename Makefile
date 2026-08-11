# Local equivalents of what CI runs, so a failure is reproducible without pushing.
#
# The AWS-touching targets expect credentials in the environment. Locally:
#
#     source .local/root-env.sh
#
# CI does not use this Makefile's AWS targets — the workflows call the same scripts
# directly with OIDC credentials.

LAYERS      := bootstrap/seed bootstrap/organization
TF_VERSION  := 1.13.3
ACCOUNT_ID  := 193027353132

.PHONY: help format fmt validate lint checks plan-seed plan-org policy-check clean

help:
	@echo "format        terraform fmt -recursive"
	@echo "validate      init -backend=false + validate, every layer"
	@echo "lint          tflint --recursive"
	@echo "checks        format check + validate + lint   (no AWS, same as CI 'checks')"
	@echo "plan-seed     plan the seed layer              (needs credentials)"
	@echo "plan-org      plan the organization layer      (needs credentials)"
	@echo "policy-check  render the SCP and run Access Analyzer + negative control"
	@echo "clean         remove generated plans and rendered policies"

format:
	terraform fmt -recursive

fmt: format

validate:
	@set -e; for d in $(LAYERS); do \
	  echo "--- $$d"; \
	  terraform -chdir=$$d init -backend=false -input=false -no-color >/dev/null; \
	  terraform -chdir=$$d validate -no-color; \
	done

# Fails with instructions when tflint is missing rather than skipping quietly. A
# check that silently does nothing reports success and is worse than no check.
lint:
	@command -v tflint >/dev/null || { \
	  echo "tflint not installed. It is NOT in homebrew-core; it needs the tap:"; \
	  echo "  brew install terraform-linters/tap/tflint"; \
	  echo "CI installs it via terraform-linters/setup-tflint, so a green CI run"; \
	  echo "does not mean this works locally."; exit 1; }
	tflint --init
	tflint --recursive --format compact

# Mirrors the credential-free CI workflow.
checks:
	terraform fmt -check -recursive -diff
	$(MAKE) validate
	$(MAKE) lint

plan-seed:
	cd bootstrap/seed && \
	terraform init -input=false -no-color -backend-config=backend.hcl && \
	terraform plan -no-color -input=false -var="management_account_id=$(ACCOUNT_ID)"

# Emails come from the environment, same as CI. Unset values fail with an explanation
# rather than reaching Terraform as empty strings.
plan-org:
	bash scripts/write-accounts-tfvars.sh bootstrap/organization/accounts.tfvars.json
	cd bootstrap/organization && \
	terraform init -input=false -no-color -backend-config=backend.hcl && \
	terraform plan -no-color -input=false -out=tfplan \
	  -var="management_account_id=$(ACCOUNT_ID)" \
	  -var-file=accounts.tfvars.json && \
	terraform show -json tfplan > plan.json

policy-check: plan-org
	bash scripts/check-policies.sh bootstrap/organization/plan.json policy-out

clean:
	rm -rf policy-out
	rm -f bootstrap/*/tfplan bootstrap/*/plan.json bootstrap/*/plan.txt
	rm -f bootstrap/*/accounts.tfvars.json
