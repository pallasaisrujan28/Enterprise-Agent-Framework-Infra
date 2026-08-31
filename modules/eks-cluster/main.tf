# The EKS control plane and who may reach it.
#
# Deliberately NOT here:
#
#   IAM roles      `modules/iam-role` is the only path that creates a role. The
#                  caller invokes it and passes ARNs in.
#   Add-ons        `modules/eks-addon`, called once per add-on. Ordering relative to
#                  the node group is a property of the composition, not of the
#                  cluster, and it cannot be expressed from in here — see below.
#   Node groups    `modules/eks-node-group`.
#
# WHY ADD-ONS CANNOT LIVE IN THIS MODULE. CoreDNS and the EBS CSI driver must be
# installed AFTER a node group exists: their pods cannot schedule on an empty
# cluster, the add-on stays DEGRADED, and Terraform waits until it times out.
# Expressing that from here would mean taking a node-group value as an input to
# create the dependency — but a module input makes the WHOLE module wait, so the
# cluster would depend on the node group, which depends on the cluster. A cycle.
# The same shape as RC2: a value needed before the resource that produces it exists.
#
# So ordering lives at the call site, where both objects are visible.

locals {
  name = "${var.org_prefix}-${var.environment}"

  mandatory_tags = {
    ManagedBy       = "terraform"
    ManagedByModule = "modules/eks-cluster"
    OrgPrefix       = var.org_prefix
    Environment     = var.environment
    Owner           = var.owner
  }

  tags = merge(var.extra_tags, local.mandatory_tags)

  # Access policy associations, flattened from the nested input into one map so each
  # association is its own resource with a stable, readable address. Keyed by entry
  # name and policy name rather than by index, so adding a policy to one principal
  # does not renumber another's.
  access_policies = merge([
    for entry_key, entry in var.access_entries : {
      for policy in entry.policies :
      "${entry_key}/${reverse(split("/", policy.policy_arn))[0]}" => {
        entry_key  = entry_key
        policy_arn = policy.policy_arn
        scope_type = upper(policy.scope_type)
        namespaces = policy.namespaces
      }
    }
  ]...)
}

# ── The cluster ───────────────────────────────────────────────────────────────

resource "aws_eks_cluster" "this" {
  name     = local.name
  role_arn = var.cluster_role_arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access

    # Only meaningful when public access is on. Sending it while public access is
    # off is rejected by the API.
    public_access_cidrs = var.endpoint_public_access ? var.public_access_cidrs : null
  }

  access_config {
    # "API", not the default.
    #
    # AWS defaults this to CONFIG_MAP when a cluster is created through the API,
    # SDKs or CloudFormation — which is Terraform's path. CONFIG_MAP is the
    # `aws-auth` ConfigMap, which AWS has DEPRECATED in favour of the Cluster Access
    # Management API, and which this repository has already been bitten by.
    #
    # Not configurable, for two reasons. The migration is ONE-WAY: once a cluster is
    # on API you cannot return to CONFIG_MAP or API_AND_CONFIG_MAP. And a module
    # whose default silently selects a deprecated authorization mechanism is a trap,
    # not a choice.
    authentication_mode = "API"

    bootstrap_cluster_creator_admin_permissions = var.bootstrap_cluster_creator_admin_permissions
  }

  upgrade_policy {
    support_type = var.support_type
  }

  enabled_cluster_log_types = var.enabled_cluster_log_types

  dynamic "kubernetes_network_config" {
    for_each = var.service_ipv4_cidr == null ? [] : [var.service_ipv4_cidr]
    content {
      service_ipv4_cidr = kubernetes_network_config.value
    }
  }

  # Envelope encryption for Secrets in etcd. Cannot be added to an existing cluster,
  # so a caller who wants it must say so before the first apply.
  dynamic "encryption_config" {
    for_each = var.secrets_kms_key_arn == null ? [] : [var.secrets_kms_key_arn]
    content {
      resources = ["secrets"]
      provider {
        key_arn = encryption_config.value
      }
    }
  }

  deletion_protection = var.deletion_protection

  tags = merge(local.tags, { Name = local.name })

  lifecycle {
    # With bootstrap_cluster_creator_admin_permissions off — the default here — the
    # ONLY way to administer the cluster is an access entry. A cluster built without
    # one is unreachable: no kubectl, no Helm, and no way to grant access afterwards
    # except by an out-of-band API call, which is the untracked-change pattern this
    # repository exists to stop.
    #
    # Checked against the policy ARN rather than a count, because an entry carrying
    # only a namespace-scoped view policy would satisfy "at least one entry" while
    # still leaving nobody able to administer anything.
    precondition {
      condition = (
        var.bootstrap_cluster_creator_admin_permissions ||
        length([
          for k, p in local.access_policies :
          k if endswith(p.policy_arn, "/AmazonEKSClusterAdminPolicy") && p.scope_type == "CLUSTER"
        ]) > 0
      )
      error_message = join(" ", [
        "Cluster ${local.name} would have no administrator.",
        "bootstrap_cluster_creator_admin_permissions is false, so access comes only from",
        "access_entries — and none of them associates AmazonEKSClusterAdminPolicy at",
        "cluster scope. Add an entry for the principal that runs this layer, or set",
        "bootstrap_cluster_creator_admin_permissions = true and accept an implicit grant."
      ])
    }

    # Both of these are create-time only. A precondition turns a confusing apply-time
    # rejection into a plan-time message that says which argument and why.
    precondition {
      condition     = var.service_ipv4_cidr == null || can(cidrnetmask(var.service_ipv4_cidr))
      error_message = "service_ipv4_cidr must be a valid CIDR block. It cannot be changed after the cluster is created."
    }
  }
}

# ── Access entries: who may talk to the Kubernetes API ────────────────────────
#
# The replacement for the `aws-auth` ConfigMap. Each entry maps an IAM principal into
# the cluster; each association grants it a scoped set of Kubernetes permissions.
# Both are real resources, so `terraform state list` answers "who can reach this
# cluster?" — which the ConfigMap never could.

resource "aws_eks_access_entry" "this" {
  for_each = var.access_entries

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  type          = each.value.type

  # Only valid for STANDARD entries. EC2_LINUX and the other node types derive their
  # identity from the node role, and sending these is rejected.
  kubernetes_groups = each.value.type == "STANDARD" ? each.value.kubernetes_groups : null
  user_name         = each.value.type == "STANDARD" ? each.value.username : null

  tags = merge(local.tags, { Name = "${local.name}-${each.key}" })
}

resource "aws_eks_access_policy_association" "this" {
  for_each = local.access_policies

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.access_entries[each.value.entry_key].principal_arn
  policy_arn    = each.value.policy_arn

  access_scope {
    type = each.value.scope_type

    # Must be absent, not empty, for a cluster-scoped association.
    namespaces = each.value.scope_type == "NAMESPACE" ? each.value.namespaces : null
  }

  # The entry has to exist before a policy can be associated with it. for_each over
  # a different map means Terraform cannot infer this from the references alone.
  depends_on = [aws_eks_access_entry.this]
}
