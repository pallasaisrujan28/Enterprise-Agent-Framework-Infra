#!/usr/bin/env bash
# Builds the `accounts` variable file for the organization layer.
#
#   scripts/write-accounts-tfvars.sh <out.tfvars.json>
#
# Reads EAF_DEV_ACCOUNT_EMAIL and EAF_PROD_ACCOUNT_EMAIL from the environment. Emails
# are never committed: they come from GitHub repository variables, or from a
# workflow_dispatch input on the run that creates the accounts.
#
# Built with jq --arg rather than string interpolation. The values arrive from a
# workflow input, so they are untrusted text; jq handles quoting and escaping and
# removes any chance of an input breaking out of the JSON.
#
# WHY EMAILS MUST BE STABLE ACROSS RUNS, which is easy to get wrong:
#
# AWS Organizations has NO API to change an account's email. Supply a different value
# later — including an empty one — and Terraform plans a change it cannot perform and
# fails mid-apply. And accounts cannot be cleanly deleted: closure takes 90 days and
# closed accounts still count against the org quota.
#
# `ignore_changes = [email, name]` on the resource is the guard, and `prevent_destroy`
# is the backstop. This script's job is to fail EARLY and clearly when a value is
# missing, rather than let an empty string reach Terraform.
set -euo pipefail

OUT="${1:?usage: write-accounts-tfvars.sh <out.tfvars.json>}"

missing=()
[[ -n "${EAF_DEV_ACCOUNT_EMAIL:-}" ]]  || missing+=("EAF_DEV_ACCOUNT_EMAIL")
[[ -n "${EAF_PROD_ACCOUNT_EMAIL:-}" ]] || missing+=("EAF_PROD_ACCOUNT_EMAIL")

if (( ${#missing[@]} )); then
  cat >&2 <<EOF
ERROR: missing account email(s): ${missing[*]}

These are not defaulted on purpose. Each AWS account needs a globally unique
address, and it becomes the root user and account-recovery address.

Set them once as GitHub repository VARIABLES (not secrets - an address is not a
credential, and treating non-secrets as secrets makes real secrets harder to audit):

  Settings > Secrets and variables > Actions > Variables

    EAF_DEV_ACCOUNT_EMAIL
    EAF_PROD_ACCOUNT_EMAIL

Plus-addressing gives two unique addresses from one inbox:

    you+eaf-dev@example.com
    you+eaf-prod@example.com

Once set, do NOT change them. AWS cannot change an account's email after creation.
EOF
  exit 1
fi

jq -n \
  --arg dev "$EAF_DEV_ACCOUNT_EMAIL" \
  --arg prod "$EAF_PROD_ACCOUNT_EMAIL" \
  '{
     accounts: {
       "EAF-DEV":  { email: $dev,  environment: "dev" },
       "EAF-PROD": { email: $prod, environment: "prod" }
     }
   }' > "$OUT"

# Print the KEYS only. Emails are not secret, but echoing them into a public build
# log for no reason is careless.
echo "wrote $OUT for accounts: $(jq -r '.accounts | keys | join(", ")' "$OUT")"
