# THE ACCOUNTS.
#
# An account is where resources actually live. Unlike an OU it has a bill, and
# unlike almost everything else in AWS it is effectively PERMANENT: closing one
# takes 90 days and a closed account still counts against the organization quota.
#
# So this is the most careful file in the repository.
#
# for_each OVER A MAP, NOT count OVER A LIST.
#
# With `count`, removing the first entry shifts every later index by one, and
# Terraform interprets that as "destroy and recreate everything after it". For
# accounts that is unrecoverable. With `for_each`, the key is the identity, so
# removing one entry affects only that entry.
#
# Adding an account later is one map entry. No new directory, no pipeline change.

resource "aws_organizations_account" "this" {
  for_each = var.accounts

  name  = each.key
  email = each.value.email

  # Placed directly in the OU, so it inherits Control Tower's baseline and our SCP
  # from the moment it exists rather than needing a follow-up move.
  parent_id = aws_organizations_organizational_unit.workloads.id

  # The cross-account role the bootstrap pipeline uses to reach into this account.
  # AWS creates it automatically at account creation and it trusts the management
  # account. This is what makes the account-baseline layer possible without storing
  # any credentials.
  #
  # `OrganizationAccountAccessRole` is the AWS default name. Kept rather than
  # renamed: every AWS tutorial, runbook and support article assumes it.
  role_name = "OrganizationAccountAccessRole"

  # Deliberately NOT set to true. `close_on_deletion = true` would mean a
  # `terraform destroy`, or a plan that decided to replace this resource, actually
  # closes a real AWS account.
  #
  # Left false so that removing the resource from Terraform merely stops managing
  # it. Closing an account should be a human decision made in the console with the
  # 90-day consequence in front of them, never a side effect of a plan.
  close_on_deletion = false

  # Billing visibility for account users. Harmless and useful; without it people
  # cannot see what their own environment costs.
  iam_user_access_to_billing = "ALLOW"

  tags = {
    Environment = each.value.environment
    Project     = var.org_prefix
  }

  lifecycle {
    # The most important two lines in this repository.
    #
    # No plan, no refactor, no accidental variable change can destroy an account.
    # If an account genuinely must go, this guard is removed in a deliberate,
    # reviewed commit — which is exactly the amount of friction the action deserves.
    prevent_destroy = true

    # `email` and `name` are ignored after creation, and the reason is not
    # convenience.
    #
    # AWS Organizations has NO API to change an account's email. If a later run
    # supplies a different value — or the pipeline input is left empty — Terraform
    # would plan a change it cannot perform and fail mid-apply, possibly after other
    # changes had already landed.
    #
    # Ignoring them makes the account's identity fixed at creation, which matches
    # reality. Changing either is a console operation with its own recovery path.
    ignore_changes = [email, name]
  }
}
