# Adopting the log group EKS already created for itself.
#
# WHY AN IMPORT IS NEEDED AT ALL. `modules/eks-cluster` now owns
# `/aws/eks/<cluster>/cluster`, but that group already exists — EKS created it on the
# control plane's first write, because `enabled_cluster_log_types` was set and nothing
# declared a destination. Verified live on 2026-09-02: 931.8 MB stored,
# `retentionInDays: NEVER EXPIRES`.
#
# Without this block the next apply fails with ResourceAlreadyExistsException. Terraform
# would be asked to create a group that is already there, and the AWS API refuses rather
# than adopting it.
#
# WHY NOT DELETE IT AND LET TERRAFORM CREATE IT FRESH. That would discard the audit history
# for a cluster whose access control has been changed several times, to save an import block.
# Importing keeps the logs, applies the 30-day retention on the next apply, and brings the
# group into state so a destroy removes it.
#
# WHAT THIS FIXES BEYOND RETENTION. The group survived the 2026-08-31 teardown, because
# deleting a cluster does not delete a log group nobody declared. Once it is in state the
# teardown takes it, which closes a leak rather than documenting one.
#
# THIS BLOCK IS SAFE TO LEAVE AND SAFE TO DELETE. Terraform skips an import whose target is
# already in state, so it is a no-op after the first apply. It can be removed in any later
# PR; it is kept for now so the adoption is visible to a reviewer rather than implied.
import {
  to = module.eks_cluster.aws_cloudwatch_log_group.cluster[0]
  id = "/aws/eks/${var.org_prefix}-${var.environment}/cluster"
}
