# THE ACCOUNTS, DRIVEN BY THE REGISTER.
#
# An account is where resources actually live. Unlike an OU it has a bill, and unlike
# almost everything else in AWS it is effectively PERMANENT: closing one takes 90 days
# and a closed account still counts against the organization quota.
#
# So this is the most careful file in the repository.

locals {
  # `accounts/register.yaml` is the source of truth for WHICH accounts exist. Read as a
  # file rather than passed as a variable, and this is the whole point of the design:
  #
  # If the account set arrived as a pipeline input, then a run that supplied only a new
  # account would make Terraform plan to DESTROY every account not mentioned. That is
  # what turns an account-vending pipeline into a one-shot script. A file that
  # accumulates means adding the tenth account cannot touch the first nine.
  #
  # `prevent_destroy` below turns that mistake into an error rather than a disaster,
  # but the register is what stops it arising.
  # `yamldecode` of a comments-only file returns NULL, not an empty map, and the register
  # is empty until the first account is requested. Without this the whole layer fails with
  # a type error on a fresh repository.
  register_raw = yamldecode(file("${path.module}/../../accounts/register.yaml"))
  register     = local.register_raw == null ? {} : local.register_raw
}

# EMAILS COME FROM SSM, NOT FROM THE REGISTER AND NOT FROM CODE.
#
# An account's email becomes its root user and its only recovery address. It is
# personal data and it is permanent, so it is kept out of git history entirely.
#
# The request-account workflow writes it once, at request time. Terraform only reads.
# The provider marks `value` as sensitive, so it does not appear in plan output or in
# the plan artifact.
#
# If this errors with ParameterNotFound, an entry was added to the register by hand
# rather than through the workflow. The fix is to store the parameter, not to hardcode
# an address:
#
#   aws ssm put-parameter --name /eaf/accounts/<NAME>/email --type String --value <addr>
data "aws_ssm_parameter" "account_email" {
  for_each = local.register

  name = "${var.email_parameter_prefix}/${each.key}/email"
}

resource "aws_organizations_account" "this" {
  # for_each OVER A MAP, NOT count OVER A LIST.
  #
  # With `count`, removing the first entry shifts every later index by one, and
  # Terraform reads that as "destroy and recreate everything after it". For AWS
  # accounts that is unrecoverable. With `for_each`, the key IS the identity, so
  # removing one entry affects only that entry.
  #
  # Adding an account later is therefore one register entry. No new directory, no
  # pipeline change, no Terraform change.
  for_each = local.register

  name  = each.key
  email = data.aws_ssm_parameter.account_email[each.key].value

  # Placed directly in the OU the register names, so it inherits that OU's Control Tower
  # baseline and SCPs from the moment it exists rather than needing a follow-up move.
  parent_id = aws_organizations_organizational_unit.this[each.value.ou].id

  # The cross-account role the bootstrap pipeline uses to reach into this account. AWS
  # creates it automatically at account creation and it trusts the management account.
  # This is what makes the account-baseline layer possible without storing any
  # credentials.
  #
  # `OrganizationAccountAccessRole` is the AWS default name. Kept rather than renamed:
  # every AWS tutorial, runbook and support article assumes it.
  role_name = "OrganizationAccountAccessRole"

  # Deliberately NOT true. `close_on_deletion = true` would mean a `terraform destroy`,
  # or a plan that decided to replace this resource, actually closes a real AWS account.
  #
  # Left false so removing the resource merely stops managing it. Closing an account
  # should be a human decision made with the 90-day consequence in front of them, never
  # a side effect of a plan.
  close_on_deletion = false

  # Billing visibility for account users. Harmless and useful; without it people cannot
  # see what their own environment costs.
  iam_user_access_to_billing = "ALLOW"

  # Tags ARE the tracking layer. "Which accounts belong to team X" is a tag query, so no
  # separate registry database is needed. CostCentre is what lets AWS Cost Explorer
  # group spend by team.
  tags = {
    Environment = each.value.environment
    Project     = each.value.project
    CostCentre  = each.value.cost_centre
    Owner       = each.value.owner
    Requested   = each.value.requested
    # Empty string when no ticket was given. Kept as a tag rather than dropped so the
    # absence is visible in the console instead of ambiguous.
    Ticket    = try(each.value.ticket, "")
    ManagedBy = "terraform"
  }

  lifecycle {
    # The most important two lines in this repository.
    #
    # No plan, no refactor, no accidental register edit can destroy an account. If one
    # genuinely must go, this guard is removed in a deliberate, reviewed commit — which
    # is exactly the amount of friction the action deserves.
    prevent_destroy = true

    # `email` and `name` are ignored after creation, and the reason is not convenience.
    #
    # AWS Organizations has NO API to change an account's email. If a later run supplied
    # a different value, Terraform would plan a change it cannot perform and fail
    # mid-apply, possibly after other changes had already landed.
    #
    # Ignoring them makes the account's identity fixed at creation, which matches
    # reality. Changing either is a console operation with its own recovery path.
    ignore_changes = [email, name]

    # Catches a bad register entry at plan time rather than mid-apply. Terraform would
    # otherwise send an invalid address to AWS and fail after other changes had landed.
    precondition {
      condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", data.aws_ssm_parameter.account_email[each.key].value))
      error_message = "The stored email for ${each.key} is not a valid address. Check ${var.email_parameter_prefix}/${each.key}/email."
    }
  }
}

# Every account must have a UNIQUE email. AWS rejects a duplicate, and two accounts
# cannot share an address.
#
# A `check` block rather than a variable validation, because the values come from SSM
# and are not known until the data sources are read. This reports as a plan warning that
# names the problem, instead of AWS failing partway through creating accounts.
check "account_emails_are_unique" {
  assert {
    condition = length(distinct([
      for name in keys(local.register) : lower(data.aws_ssm_parameter.account_email[name].value)
    ])) == length(local.register)
    error_message = "Two accounts in the register resolve to the same email. AWS rejects duplicates. Check the parameters under ${var.email_parameter_prefix}."
  }
}
