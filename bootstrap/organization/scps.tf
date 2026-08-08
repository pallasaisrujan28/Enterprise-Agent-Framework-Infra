# OUR SERVICE CONTROL POLICY.
#
# An SCP is a CEILING on a whole account. It grants nothing. It removes
# permissions from every principal in the account — including administrators and
# including the root user — and it cannot be overridden from inside the account.
#
# That is what makes it different from the permissions boundary the account
# baseline will create: a boundary applies only to principals it is attached to, so
# a role created without it escapes. An SCP has no such escape.
#
# ONE POLICY, NOT FIVE — AND THIS IS FORCED, NOT STYLISTIC.
#
# The implementation spec lists five separate SCPs. AWS allows a maximum of FIVE
# policies attached per target, and Control Tower already consumes several of that
# budget on every OU it governs (the Sandbox OU has three attached today, including
# FullAWSAccess which is mandatory). Five of ours plus Control Tower's would exceed
# the limit, and the failure arrives at attach time.
#
# So the spec's five concerns become five STATEMENTS in one policy. Same effect, one
# attachment.
#
# WHAT IS DELIBERATELY ABSENT: deny-root-access, deny-leave-org,
# deny-disable-cloudtrail. Control Tower's baseline already enforces all three on
# enrolled OUs. Duplicating them would burn the attachment budget to restate rules
# that are already active.

data "aws_iam_policy_document" "workloads_guardrails" {

  # --- 1. Region restriction — the residency control -----------------------
  #
  # The reason this project cares: the anchor use case answers questions about UK
  # statute, so inference and data staying in the UK is a product property.
  #
  # This is also how the problem was FOUND. A cross-region Bedrock inference
  # profile called in eu-west-2 dispatched to eu-north-1 on six of six attempts.
  # The account with a region SCP refused it; the account without one accepted it
  # silently for weeks. The permissive environment was the misleading one.
  #
  # not_actions exempts services whose endpoints are global and which therefore
  # report a region the caller did not choose. Without the exemption this denies
  # sts:AssumeRole, which breaks assuming any role at all — and presents as a
  # broken credential rather than a policy problem.
  statement {
    sid       = "DenyOutsideApprovedRegions"
    effect    = "Deny"
    resources = ["*"]

    not_actions = [
      "iam:*",
      "sts:*",
      "organizations:*",
      "account:*",
      "cloudfront:*",
      "route53:*",
      "route53domains:*",
      "support:*",
      "budgets:*",
      "ce:*",
      "cur:*",
      "globalaccelerator:*",
      "health:*",
      "shield:*",
      "waf:*",
      "trustedadvisor:*",
      "controltower:*",
      "sso:*",
      "sso-directory:*",
      "identitystore:*",
      "artifact:*",
      "servicequotas:*",
      "s3:ListAllMyBuckets",
      "s3:GetBucketLocation",
    ]

    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = var.approved_regions
    }
  }

  # --- 2. Cross-region model dispatch ------------------------------------
  #
  # Region restriction alone does not cover this, which is the subtle part. A
  # Bedrock inference profile is a DISPATCHER: the caller invokes the profile in an
  # approved region, and Bedrock forwards to a foundation model wherever capacity
  # is. The call looks local and is not.
  #
  # Denying the profile resource types forces on-demand invocation of a named model
  # in a named region, which is what actually keeps inference in London.
  #
  # Note the actions. `bedrock:Converse` and `bedrock:ConverseStream` are NOT IAM
  # actions — Access Analyzer rejects them as nonexistent. The Converse API is
  # authorized by InvokeModel and InvokeModelWithResponseStream. Naming the API
  # rather than the IAM action would produce a policy that silently denies nothing.
  statement {
    sid    = "DenyCrossRegionInferenceDispatch"
    effect = "Deny"

    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]

    resources = [
      "arn:${local.partition}:bedrock:*:*:inference-profile/*",
      "arn:${local.partition}:bedrock:*:*:application-inference-profile/*",
    ]
  }

  # --- 3. No long-lived credentials -------------------------------------
  #
  # Nothing in these accounts may mint a permanent credential — not an IAM user,
  # not an access key, not a console password.
  #
  # Enforced rather than documented because a permanent credential is the failure
  # mode with the longest tail: it works, so nobody revisits it, and it is still
  # working the day it leaks. Everything here authenticates by federation or role
  # assumption, both of which expire on their own.
  statement {
    sid    = "DenyLongLivedCredentials"
    effect = "Deny"

    actions = [
      "iam:CreateUser",
      "iam:CreateAccessKey",
      "iam:UpdateAccessKey",
      "iam:CreateLoginProfile",
      "iam:UpdateLoginProfile",
      "iam:CreateServiceSpecificCredential",
      "iam:ResetServiceSpecificCredential",
      "iam:UploadSSHPublicKey",
    ]

    resources = ["*"]
  }

  # --- 4. S3 must not be public ------------------------------------------
  #
  # Account-level public access block cannot be weakened. The classic data breach
  # is a bucket someone made public "temporarily".
  statement {
    sid    = "DenyS3PublicAccessWeakening"
    effect = "Deny"

    # `s3:PutAccountPublicAccessBlock` ONLY.
    #
    # An earlier version also denied `s3:DeleteAccountPublicAccessBlock`, which
    # Access Analyzer rejected: that action does not exist. There is no Delete
    # variant — the block is removed by PUTTING one with every flag false. So
    # denying Put covers both creating a weaker block and removing an existing one.
    #
    # Worth noting because the nonexistent action was not harmless. An unknown
    # action inside a Deny denies nothing, and the policy would have read as
    # stronger than it was. This is the third error of exactly this shape found by
    # running the validator rather than reasoning about the JSON.
    actions = ["s3:PutAccountPublicAccessBlock"]

    resources = ["*"]
  }

  # --- 5. Do not blind the auditor --------------------------------------
  #
  # Control Tower already protects CloudTrail and Config on enrolled OUs. This adds
  # the services it does not cover, so a compromised principal cannot switch off
  # threat detection before acting.
  #
  # If logging can be stopped, the logs stop being evidence exactly when they
  # matter.
  statement {
    sid    = "DenyDisablingSecurityServices"
    effect = "Deny"

    actions = [
      "guardduty:DeleteDetector",
      "guardduty:DisassociateFromMasterAccount",
      "guardduty:UpdateDetector",
      "securityhub:DisableSecurityHub",
      "securityhub:DeleteMembers",
      # The IAM service prefix is `access-analyzer`, WITH the hyphen. Access
      # Analyzer rejects the unhyphenated form as an unknown service, and an
      # unknown service inside a Deny denies nothing at all.
      "access-analyzer:DeleteAnalyzer",
      "inspector2:Disable",
    ]

    resources = ["*"]
  }
}

resource "aws_organizations_policy" "workloads_guardrails" {
  name        = "${var.org_prefix}-workloads-guardrails"
  description = "Residency, credential and audit guardrails for the ${var.ou_name} OU. Additive to Control Tower's controls."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.workloads_guardrails.json
}

# Attached to the OU ONLY. Never to the root, and never to an OU another team owns
# — an SCP on the root would apply to all 25 accounts in this organization,
# including client production work.
resource "aws_organizations_policy_attachment" "workloads_guardrails" {
  policy_id = aws_organizations_policy.workloads_guardrails.id
  target_id = aws_organizations_organizational_unit.workloads.id
}
