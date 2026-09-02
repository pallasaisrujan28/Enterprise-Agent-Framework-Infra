# Unit tests for modules/iam-role.
#
# Every run block uses `command = plan`, so nothing is created and no AWS
# credentials are needed. This is the module half of Step 1's local loop: it runs
# in seconds, offline, and catches the two classes of IAM error that have cost this
# project the most time.
#
# Half of these tests assert that BAD input is rejected. A guardrail nobody has
# seen fail is not known to work.

# No credentials, and this time the claim is testable.
#
# Unsetting AWS_* environment variables is NOT sufficient evidence of that, which is what
# the previous version of this comment asserted. The AWS credential chain continues on to
# ~/.aws/credentials, so a suite that reads "passes with the environment unset" can still be
# quietly using a developer's local profile — and then fail on a runner that has none.
#
# The check that actually holds it:
#
#   HOME=/tmp/nohome AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null \
#     terraform -chdir=modules/iam-role test
#
# `make test` now sets exactly that, so a local run and a CI run see the same absence of
# credentials rather than differing by the contents of a home directory.
#
# An earlier revision set access_key = "mock" / secret_key = "mock" here. They were
# unnecessary, and a committed file containing something shaped like a credential is
# noise for a reviewer and for secret scanning. Removed.
# mock_provider, matching every other module in this repository.
#
# THE PREVIOUS VERSION WAS A REAL `provider "aws"` BLOCK WITH THREE skip_* FLAGS, AND IT
# NEEDED CREDENTIALS.
#
# The flags stop the provider validating credentials, looking up the account id, and
# reaching the instance metadata endpoint. What they do not do is remove the need for a
# credential source to exist: the provider still resolves the default chain when it
# configures, and with nothing to find it fails with "No valid credential sources found"
# before a single run block executes. 0 passed, 26 skipped.
#
# It appeared to work because the default chain reaches ~/.aws/credentials, which exists on
# a developer laptop and does not exist on a CI runner. The file's own header claimed this
# suite was "verified" with the AWS_* environment variables unset — and that verification
# was invalid, because unsetting environment variables does not disable the shared
# credentials file. The claim was stronger than the evidence behind it.
#
# mock_provider needs no credential source at all, which is why the other five aws-using
# modules already use it.
mock_provider "aws" {}

variables {
  org_prefix   = "eaf"
  environment  = "dev"
  layer        = "platform"
  purpose      = "deployer"
  description  = "Assumed by the infra pipeline to apply the platform layer."
  owner        = "platform-team"
  boundary_arn = "arn:aws:iam::111122223333:policy/eaf-dev-deployer-boundary"

  trust = {
    type = "github_oidc"
    github_oidc = {
      oidc_provider_arn = "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com"
      owner             = "pallasaisrujan28"
      owner_id          = "194785418"
      repository        = "Enterprise-Agent-Framework-Infra"
      repository_id     = "1324052608"
      contexts          = ["environment:dev"]
    }
  }
}

# ── Naming ────────────────────────────────────────────────────────────────────

run "name_is_generated_from_identity" {
  command = plan

  assert {
    condition     = aws_iam_role.this.name == "eaf-dev-platform-deployer-role"
    error_message = "Expected generated name eaf-dev-platform-deployer-role, got ${aws_iam_role.this.name}"
  }
}

run "mandatory_tags_are_present_and_not_overridable" {
  command = plan

  variables {
    # Attempt to override a mandatory tag. The module merges extra_tags FIRST, so
    # the generated value must win.
    extra_tags = { ManagedBy = "definitely-not-terraform", CostCentre = "CC-1001" }
  }

  assert {
    condition     = aws_iam_role.this.tags["ManagedBy"] == "terraform"
    error_message = "extra_tags overrode a mandatory tag: ManagedBy is ${aws_iam_role.this.tags["ManagedBy"]}"
  }

  assert {
    condition     = aws_iam_role.this.tags["Layer"] == "platform"
    error_message = "Layer tag missing or wrong — it is the locator for which directory owns the role."
  }

  assert {
    condition     = aws_iam_role.this.tags["CostCentre"] == "CC-1001"
    error_message = "extra_tags should still be merged for non-mandatory keys."
  }
}

# ── GitHub OIDC trust ─────────────────────────────────────────────────────────

run "github_oidc_emits_immutable_subject" {
  command = plan

  assert {
    condition = contains(
      jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringLike["token.actions.githubusercontent.com:sub"],
      "repo:pallasaisrujan28@194785418/Enterprise-Agent-Framework-Infra@1324052608:environment:dev"
    )
    error_message = "Immutable subject not emitted. A trust policy in the legacy repo:owner/repo form silently never matches."
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    )
    error_message = "aud condition missing. Without it the trust policy is broader than intended."
  }

  assert {
    condition     = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity"
    error_message = "OIDC federation requires sts:AssumeRoleWithWebIdentity, not sts:AssumeRole."
  }
}

run "github_oidc_legacy_subject_when_immutable_disabled" {
  command = plan

  variables {
    trust = {
      type = "github_oidc"
      github_oidc = {
        oidc_provider_arn = "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com"
        owner             = "octo-org"
        repository        = "octo-repo"
        immutable_subject = false
        contexts          = ["ref:refs/heads/main"]
      }
    }
  }

  assert {
    condition = contains(
      jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringLike["token.actions.githubusercontent.com:sub"],
      "repo:octo-org/octo-repo:ref:refs/heads/main"
    )
    error_message = "Legacy subject form not emitted when immutable_subject = false."
  }
}

run "reject_immutable_subject_without_ids" {
  command = plan

  variables {
    trust = {
      type = "github_oidc"
      github_oidc = {
        oidc_provider_arn = "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com"
        owner             = "octo-org"
        repository        = "octo-repo"
        contexts          = ["environment:dev"]
      }
    }
  }

  expect_failures = [var.trust]
}

run "reject_bare_branch_name_as_context" {
  command = plan

  variables {
    trust = {
      type = "github_oidc"
      github_oidc = {
        oidc_provider_arn = "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com"
        owner             = "octo-org"
        owner_id          = "1"
        repository        = "octo-repo"
        repository_id     = "2"
        contexts          = ["main"]
      }
    }
  }

  expect_failures = [var.trust]
}

run "reject_empty_context_list" {
  command = plan

  variables {
    trust = {
      type = "github_oidc"
      github_oidc = {
        oidc_provider_arn = "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com"
        owner             = "octo-org"
        owner_id          = "1"
        repository        = "octo-repo"
        repository_id     = "2"
        contexts          = []
      }
    }
  }

  expect_failures = [var.trust]
}

run "reject_payload_not_matching_declared_type" {
  command = plan

  variables {
    trust = {
      type = "eks_irsa"
      github_oidc = {
        oidc_provider_arn = "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com"
        owner             = "octo-org"
        owner_id          = "1"
        repository        = "octo-repo"
        repository_id     = "2"
        contexts          = ["environment:dev"]
      }
    }
  }

  expect_failures = [var.trust]
}

# ── IRSA trust ────────────────────────────────────────────────────────────────

run "irsa_emits_both_sub_and_aud" {
  command = plan

  variables {
    layer   = "platform"
    purpose = "agent"
    trust = {
      type = "eks_irsa"
      eks_irsa = {
        oidc_provider_arn = "arn:aws:iam::111122223333:oidc-provider/oidc.eks.eu-west-2.amazonaws.com/id/ABCDEF"
        namespace         = "eaf"
        service_account   = "eaf-agent"
      }
    }
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.eu-west-2.amazonaws.com/id/ABCDEF:sub"] == "system:serviceaccount:eaf:eaf-agent"
    )
    error_message = "IRSA sub condition wrong or missing."
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.eu-west-2.amazonaws.com/id/ABCDEF:aud"] == "sts.amazonaws.com"
    )
    error_message = "IRSA aud condition missing — a documented way to make the trust policy too broad."
  }
}

# ── Pod Identity ─────────────────────────────────────────────────────────────

run "pod_identity_emits_the_documented_trust_shape" {
  command = plan

  variables {
    layer   = "platform"
    purpose = "agent"
    trust = {
      type = "eks_pod_identity"
      eks_pod_identity = {
        namespace       = "eaf"
        service_account = "eaf-agent"
      }
    }
  }

  assert {
    condition = (
      one(jsondecode(aws_iam_role.this.assume_role_policy).Statement).Principal.Service == "pods.eks.amazonaws.com"
    )
    error_message = "Pod Identity trust must name the pods.eks.amazonaws.com service principal."
  }

  # Both actions, always. EKS always sends session tags, so a trust policy granting
  # only sts:AssumeRole fails the assumption.
  assert {
    condition = (
      join(",", sort(one(jsondecode(aws_iam_role.this.assume_role_policy).Statement).Action))
      == "sts:AssumeRole,sts:TagSession"
    )
    error_message = "Pod Identity trust must allow both sts:AssumeRole and sts:TagSession."
  }

  # No OIDC anything. This is the whole point of the mechanism.
  assert {
    condition     = !strcontains(aws_iam_role.this.assume_role_policy, "oidc")
    error_message = "a Pod Identity trust policy should reference no OIDC provider or issuer."
  }

  assert {
    condition     = !strcontains(aws_iam_role.this.assume_role_policy, "AssumeRoleWithWebIdentity")
    error_message = "Pod Identity uses sts:AssumeRole, not sts:AssumeRoleWithWebIdentity."
  }
}

run "pod_identity_always_scopes_to_namespace_and_service_account" {
  command = plan

  variables {
    layer   = "platform"
    purpose = "agent"
    trust = {
      type = "eks_pod_identity"
      eks_pod_identity = {
        namespace       = "eaf"
        service_account = "eaf-agent"
      }
    }
  }

  # The regression guarded here: AWS's own documented example trust policy carries
  # NO conditions, which permits any pod in any namespace in any cluster in the
  # account. That is broader than the IRSA policy this replaces, so the module emits
  # the conditions whether or not the caller thought to ask.
  assert {
    condition = (
      one(jsondecode(aws_iam_role.this.assume_role_policy).Statement).Condition.StringEquals["aws:RequestTag/kubernetes-namespace"] == "eaf"
    )
    error_message = "namespace condition missing — the role would be assumable from any namespace."
  }

  assert {
    condition = (
      one(jsondecode(aws_iam_role.this.assume_role_policy).Statement).Condition.StringEquals["aws:RequestTag/kubernetes-service-account"] == "eaf-agent"
    )
    error_message = "service account condition missing — the role would be assumable by any service account."
  }

  # aws:RequestTag, not aws:PrincipalTag. Both key families accept the same six tag
  # names, so the wrong one yields valid JSON that applies cleanly and never
  # matches. Trust policies condition on the request.
  assert {
    condition     = !strcontains(aws_iam_role.this.assume_role_policy, "aws:PrincipalTag")
    error_message = "trust policy used aws:PrincipalTag; session tags on an AssumeRole request are aws:RequestTag."
  }

  # Absent cluster_names means any cluster, which is the reuse property.
  assert {
    condition     = !strcontains(aws_iam_role.this.assume_role_policy, "eks-cluster-name")
    error_message = "no cluster condition should be emitted when cluster_names is omitted."
  }
}

run "pod_identity_can_be_pinned_to_named_clusters" {
  command = plan

  variables {
    layer   = "platform"
    purpose = "agent"
    trust = {
      type = "eks_pod_identity"
      eks_pod_identity = {
        namespace       = "eaf"
        service_account = "eaf-agent"
        cluster_names   = ["eaf-dev", "eaf-dev-blue"]
      }
    }
  }

  assert {
    condition = (
      join(",", one(jsondecode(aws_iam_role.this.assume_role_policy).Statement).Condition.StringEquals["aws:RequestTag/eks-cluster-name"])
      == "eaf-dev,eaf-dev-blue"
    )
    error_message = "cluster_names should emit an eks-cluster-name condition listing exactly those clusters."
  }
}

run "reject_empty_cluster_names" {
  command = plan

  variables {
    layer   = "platform"
    purpose = "agent"
    trust = {
      type = "eks_pod_identity"
      eks_pod_identity = {
        namespace       = "eaf"
        service_account = "eaf-agent"
        # An empty list emits a condition with no permitted values, which never
        # matches. Omission is how you say "any cluster".
        cluster_names = []
      }
    }
  }

  expect_failures = [var.trust]
}

run "reject_namespace_that_kubernetes_cannot_create" {
  command = plan

  variables {
    layer   = "platform"
    purpose = "agent"
    trust = {
      type = "eks_pod_identity"
      eks_pod_identity = {
        # Uppercase is not a valid RFC 1123 label. An association may name objects
        # that do not exist yet, so nothing would report this until the pod failed.
        namespace       = "EAF_Prod"
        service_account = "eaf-agent"
      }
    }
  }

  expect_failures = [var.trust]
}

run "reject_pod_identity_payload_with_irsa_type" {
  command = plan

  variables {
    layer   = "platform"
    purpose = "agent"
    trust = {
      type = "eks_irsa"
      eks_pod_identity = {
        namespace       = "eaf"
        service_account = "eaf-agent"
      }
    }
  }

  expect_failures = [var.trust]
}

# ── The issuer host is derived, never assumed ────────────────────────────────

run "github_issuer_host_comes_from_the_provider_arn" {
  command = plan

  variables {
    layer   = "platform"
    purpose = "ci-runner"
    trust = {
      type = "github_oidc"
      github_oidc = {
        # A GitHub Enterprise Server appliance. Its issuer is the appliance host, not
        # token.actions.githubusercontent.com — so a module with that host written in
        # as a literal emits a trust policy that can never match.
        oidc_provider_arn = "arn:aws:iam::111122223333:oidc-provider/github.example.com/_services/token"
        owner             = "acme"
        owner_id          = "1"
        repository        = "infra"
        repository_id     = "2"
        contexts          = ["ref:refs/heads/main"]
      }
    }
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringEquals["github.example.com/_services/token:aud"] == "sts.amazonaws.com"
    )
    error_message = "aud condition key did not use the issuer from the provider ARN."
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringLike["github.example.com/_services/token:sub"][0] == "repo:acme@1/infra@2:ref:refs/heads/main"
    )
    error_message = "sub condition key did not use the issuer from the provider ARN."
  }

  # And nothing anywhere in the policy mentions the github.com issuer.
  assert {
    condition     = !strcontains(aws_iam_role.this.assume_role_policy, "token.actions.githubusercontent.com")
    error_message = "the github.com issuer host is hardcoded somewhere in the trust policy."
  }
}

run "reject_issuer_url_passed_instead_of_provider_arn" {
  command = plan

  variables {
    layer   = "platform"
    purpose = "ci-runner"
    trust = {
      type = "github_oidc"
      github_oidc = {
        # The most likely mistake now that the issuer is derived: passing the URL.
        oidc_provider_arn = "https://token.actions.githubusercontent.com"
        owner             = "acme"
        owner_id          = "1"
        repository        = "infra"
        repository_id     = "2"
        contexts          = ["ref:refs/heads/main"]
      }
    }
  }

  expect_failures = [var.trust]
}

# ── Permissions boundary ──────────────────────────────────────────────────────

run "reject_no_boundary_and_no_exemption" {
  command = plan

  variables {
    boundary_arn = null
  }

  expect_failures = [var.boundary_exemption_reason]
}

run "reject_both_boundary_and_exemption" {
  command = plan

  variables {
    boundary_arn              = "arn:aws:iam::111122223333:policy/eaf-dev-deployer-boundary"
    boundary_exemption_reason = "This role is exempt for a reason that is long enough."
  }

  expect_failures = [var.boundary_exemption_reason]
}

run "accept_explicit_boundary_exemption" {
  command = plan

  variables {
    boundary_arn              = null
    boundary_exemption_reason = "Management account bootstrap role; no workload boundary exists in that account."
  }

  assert {
    condition     = aws_iam_role.this.tags["Boundary"] == "EXEMPT"
    error_message = "An exempt role must be tagged EXEMPT so the inventory can surface it."
  }
}

# ── PassRole scoping ──────────────────────────────────────────────────────────

run "pass_role_generates_scoped_policy" {
  command = plan

  variables {
    pass_role_arns = [
      "arn:aws:iam::111122223333:role/eaf-dev-platform-cluster-role",
      "arn:aws:iam::111122223333:role/eaf-dev-platform-node-role",
    ]
  }

  assert {
    condition     = contains(keys(aws_iam_role_policy.inline), "scoped-pass-role")
    error_message = "Expected a generated scoped-pass-role inline policy."
  }

  assert {
    condition = length(
      jsondecode(aws_iam_role_policy.inline["scoped-pass-role"].policy).Statement[0].Resource
    ) == 2
    error_message = "PassRole policy should name exactly the two supplied role ARNs."
  }
}

run "reject_wildcard_pass_role" {
  command = plan

  variables {
    pass_role_arns = ["*"]
  }

  expect_failures = [var.pass_role_arns]
}

# ── Identity validation ───────────────────────────────────────────────────────

run "reject_non_kebab_purpose" {
  command = plan

  variables {
    purpose = "Deployer_Role"
  }

  expect_failures = [var.purpose]
}

run "reject_unknown_layer" {
  command = plan

  variables {
    layer = "workloads"
  }

  expect_failures = [var.layer]
}

run "reject_short_description" {
  command = plan

  variables {
    description = "deployer"
  }

  expect_failures = [var.description]
}

# ── Exclusivity ───────────────────────────────────────────────────────────────

run "exclusive_management_on_by_default" {
  command = plan

  assert {
    condition     = length(aws_iam_role_policies_exclusive.this) == 1
    error_message = "Exclusive inline-policy management should be enabled by default — it is what makes out-of-band drift self-correcting."
  }

  assert {
    condition     = length(aws_iam_role_policy_attachments_exclusive.this) == 1
    error_message = "Exclusive managed-policy-attachment management should be enabled by default."
  }
}
