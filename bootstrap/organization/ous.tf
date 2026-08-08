# THE OU — a folder that rules attach to.
#
# An OU holds no resources and costs nothing. Its entire purpose is to be
# something policies attach to: every account inside inherits them, so adding an
# account later needs no extra policy work.
#
# Created directly under the ORGANIZATIONAL ROOT, alongside the six that already
# exist. Nothing existing is touched or moved.

resource "aws_organizations_organizational_unit" "workloads" {
  name      = var.ou_name
  parent_id = local.org_root_id

  # Cheap and reversible compared with an account, but deleting it would orphan
  # the accounts inside — AWS refuses to delete a non-empty OU, and the recovery is
  # manual. Guarded because the cost of the guard is nil.
  lifecycle {
    prevent_destroy = true
  }
}

# CONTROL TOWER ENROLMENT.
#
# Registers the OU so it inherits the same baseline the other six OUs run: 16
# controls covering CloudTrail enabled and unmodifiable, Config recording, region
# deny, and protection of Control Tower's own roles.
#
# Why enrol rather than hand-roll equivalents: those 16 controls exist because AWS
# worked out what people forget. Writing our own means owning the gaps AND running
# a second governance model in parallel with the org's real one. The divergence is
# the risk, more than any individual missing control.
#
# Every value here was read from this organization rather than recalled:
#   baseline ARN      aws controltower list-baselines
#   version 3.0       aws controltower list-enabled-baselines   (a guess said 4.0)
#   the parameter     aws controltower get-enabled-baseline     (would have been missed)
resource "aws_controltower_baseline" "workloads" {
  count = var.enroll_in_control_tower ? 1 : 0

  baseline_identifier = var.control_tower_baseline_arn
  baseline_version    = var.control_tower_baseline_version
  target_identifier   = aws_organizations_organizational_unit.workloads.arn

  parameters {
    key   = "IdentityCenterEnabledBaselineArn"
    value = var.identity_center_baseline_arn
  }

  # Control Tower enrolment provisions across accounts and is slow. The default
  # timeout is optimistic for an OU that will contain accounts.
  timeouts {
    create = "120m"
    update = "120m"
    delete = "120m"
  }
}
