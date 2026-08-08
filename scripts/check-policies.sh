#!/usr/bin/env bash
# Validates the rendered SCP with IAM Access Analyzer, then proves the validator can
# still fail.
#
#   scripts/check-policies.sh <plan.json> <workdir>
#
# Takes an ALREADY RENDERED plan so it never plans twice. `terraform show -json
# tfplan > plan.json` produces the input.
#
# Credentials come from the ambient environment. In CI that is the OIDC role; locally
# `source .local/root-env.sh` first. Nothing here reads a credential file, so this
# script is safe to commit.
#
# Needs access-analyzer:ValidatePolicy, which IS included in the AWS managed
# ReadOnlyAccess policy — verified against version v188 rather than assumed.
set -euo pipefail

PLAN_JSON="${1:?usage: check-policies.sh <plan.json> <workdir>}"
WORKDIR="${2:?usage: check-policies.sh <plan.json> <workdir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$WORKDIR"

SCP="$WORKDIR/scp-rendered.json"
BAD="$WORKDIR/scp-bad.json"

echo "::group::render the policy from the plan"
python3 "$HERE/extract_scp.py" "$PLAN_JSON" "$SCP"
echo "::endgroup::"

echo "::group::Access Analyzer on the real policy"
# --policy-type matters. Validated as an identity policy instead, Access Analyzer
# applies the wrong rules and reports findings that do not apply to SCPs.
aws accessanalyzer validate-policy \
  --policy-document "file://$SCP" \
  --policy-type SERVICE_CONTROL_POLICY \
  --output json > "$WORKDIR/findings.json"

python3 "$HERE/report_findings.py" "$WORKDIR/findings.json"
echo "::endgroup::"

echo "::group::negative control - the validator must still reject bad actions"
python3 "$HERE/make_bad_policy.py" "$SCP" "$BAD"

aws accessanalyzer validate-policy \
  --policy-document "file://$BAD" \
  --policy-type SERVICE_CONTROL_POLICY \
  --output json > "$WORKDIR/findings-bad.json"

python3 "$HERE/report_findings.py" "$WORKDIR/findings-bad.json" --expect-failure
echo "::endgroup::"

rm -f "$BAD" "$WORKDIR/findings-bad.json"
echo "policy checks passed"
