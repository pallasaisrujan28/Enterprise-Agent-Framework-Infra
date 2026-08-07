# STATE BACKEND for this repository's own Terraform.
#
# Created here because the configurations that use it cannot create it. Every
# other layer — organization, accounts, sso — keeps its state in this bucket under
# a distinct key, so a change to one never carries another's blast radius.

resource "aws_s3_bucket" "state" {
  # Bucket names are globally unique across all of AWS, so the account id is
  # included. Without it, `eaf-bootstrap-tfstate` is a name someone else may
  # already hold, and the failure is a confusing 403 rather than a clear conflict.
  bucket = "${var.org_prefix}-bootstrap-tfstate-${local.account_id}"

  # State is the record of what exists. Losing it does not destroy infrastructure,
  # but it means Terraform no longer knows what it manages — close to as bad, and
  # considerably harder to unpick.
  #
  # Note for teardown: this guard must be removed deliberately, and a versioned
  # bucket will not delete until every version AND delete-marker is purged.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    # The recovery mechanism for a corrupted or truncated state write, which is
    # the failure that actually happens.
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3 rather than SSE-KMS, deliberately. KMS adds a key policy that every
      # future principal touching state must also be granted on — a second
      # access-control surface to keep in sync. Worth it for state holding real
      # secrets; the rule here is that secrets stay out of state instead.
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      # Long enough to recover from a bad write discovered late; short enough that
      # the bucket does not accumulate every revision forever.
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# TLS is not optional. Without this a misconfigured client could send state —
# which contains resolved resource attributes — over plaintext HTTP.
data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid    = "DenyUnencryptedTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json
}

# Optional DynamoDB lock table, off by default.
#
# Present only so `state_lock_mode = "dynamodb"` is available without editing
# code. S3-native locking (`use_lockfile = true`) is the default and the
# non-deprecated path — see the variable's description.
resource "aws_dynamodb_table" "lock" {
  count = var.state_lock_mode == "dynamodb" ? 1 : 0

  name         = "${var.org_prefix}-bootstrap-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = true
  }
}
