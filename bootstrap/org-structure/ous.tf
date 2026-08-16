# THE OUs — folders that rules attach to.
#
# An OU holds no resources and costs nothing. Its entire purpose is to be something
# policies attach to: every account inside inherits them, so adding an account later
# needs no extra policy work.
#
# `Workloads` is only a NAME. It is not a special kind of object. Six other OUs already
# exist alongside it (Sandbox, Security, MLOps, Apps, Sprint BE, Clients) and they are
# the same kind of thing, owned by other teams.
#
# DERIVED FROM THE REGISTER, NOT HARDCODED.
#
# Every distinct `ou:` value in accounts/register.yaml becomes an OU. That is what lets
# one repository serve several projects: a new entry naming a new OU creates it, and the
# account lands inside it with that OU's policies already applied.

locals {
  # Distinct OU names the register asks for. `toset` because the same OU appears once per
  # account that lives in it, and we want one resource per OU rather than per account.
  requested_ous = toset([for name, entry in local.register : entry.ou])
}

# REFUSE TO TOUCH ANOTHER TEAM'S OU.
#
# This organization is not a sandbox. It holds 25 accounts including client and
# production work, governed by Control Tower.
#
# Naming an existing OU in the register would fail at create time anyway — AWS rejects a
# duplicate name under the same parent — but that failure reads as a naming clash rather
# than "you tried to take over someone else's governance". This check states the intent
# and fails at plan time instead.
check "register_does_not_claim_a_protected_ou" {
  assert {
    condition     = length(setintersection(local.requested_ous, toset(var.protected_ou_names))) == 0
    error_message = "The register names an OU this repository must not manage: ${join(", ", setintersection(local.requested_ous, toset(var.protected_ou_names)))}. Those OUs belong to other teams. Pick a different name."
  }
}

resource "aws_organizations_organizational_unit" "this" {
  for_each = local.requested_ous

  name      = each.value
  parent_id = local.org_root_id

  # Cheap and reversible compared with an account, but deleting one would orphan the
  # accounts inside — AWS refuses to delete a non-empty OU, and the recovery is manual.
  # Guarded because the cost of the guard is nil.
  lifecycle {
    prevent_destroy = true
  }
}

# CONTROL TOWER ENROLMENT, per OU.
#
# Registers each OU we create so it inherits the same baseline the other six OUs run: 16
# controls covering CloudTrail enabled and unmodifiable, Config recording, region deny,
# and protection of Control Tower's own roles.
#
# Why enrol rather than hand-roll equivalents: those 16 controls exist because AWS worked
# out what people forget. Writing our own means owning the gaps AND running a second
# governance model in parallel with the org's real one. The divergence is the risk, more
# than any individual missing control.
#
# This ADDS enrolment for OUs we created. It does not re-enrol or modify the six that
# already exist — they are not in `local.requested_ous`, and the protected-name check
# above stops them getting there.
#
# Every value here was read from this organization rather than recalled:
#   baseline ARN      aws controltower list-baselines
#   version 3.0       aws controltower list-enabled-baselines   (a guess said 4.0)
#   the parameter     aws controltower get-enabled-baseline     (would have been missed)
resource "aws_controltower_baseline" "this" {
  for_each = var.enroll_in_control_tower ? aws_organizations_organizational_unit.this : {}

  baseline_identifier = var.control_tower_baseline_arn
  baseline_version    = var.control_tower_baseline_version
  target_identifier   = each.value.arn

  parameters {
    key   = "IdentityCenterEnabledBaselineArn"
    value = var.identity_center_baseline_arn
  }

  # Control Tower enrolment provisions across accounts and is slow. The default timeout is
  # optimistic for an OU that will contain accounts.
  timeouts {
    create = "120m"
    update = "120m"
    delete = "120m"
  }
}
