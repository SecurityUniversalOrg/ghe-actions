data "aws_caller_identity" "current" {}

locals {
  allowed_subjects = flatten([
    for repo in var.allowed_repositories : [
      for branch in var.allowed_branches :
      "repo:${var.github_org}/${repo}:ref:refs/heads/${branch}"
    ]
  ])
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # Validate this thumbprint in your environment and manage through change control.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = var.tags
}

resource "aws_iam_role" "github_source_exporter" {
  name                 = "GitHubSourceExportToAISecurityLab"
  assume_role_policy   = data.aws_iam_policy_document.github_source_exporter_trust.json
  max_session_duration = 3600
  tags                 = var.tags
}

data "aws_iam_policy_document" "github_source_exporter_trust" {
  statement {
    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.allowed_subjects
    }
  }
}

resource "aws_iam_role" "validation_lambda" {
  name               = "AISecurityLabSourceIngestionValidator"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_kms_key" "source_ingestion" {
  description             = "KMS key for AI Security Lab source ingestion packages"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_key_policy.json
  tags                    = var.tags
}

resource "aws_kms_alias" "source_ingestion" {
  name          = "alias/ai-security-lab-source-ingestion"
  target_key_id = aws_kms_key.source_ingestion.key_id
}

data "aws_iam_policy_document" "kms_key_policy" {
  statement {
    sid    = "EnableRootAccountPermissions"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = toset(var.kms_admin_role_arns)
    content {
      sid    = "AllowKmsAdmins"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = [statement.value]
      }

      actions = [
        "kms:Create*",
        "kms:Describe*",
        "kms:Enable*",
        "kms:List*",
        "kms:Put*",
        "kms:Update*",
        "kms:Revoke*",
        "kms:Disable*",
        "kms:Get*",
        "kms:Delete*",
        "kms:TagResource",
        "kms:UntagResource",
        "kms:ScheduleKeyDeletion",
        "kms:CancelKeyDeletion"
      ]

      resources = ["*"]
    }
  }

  statement {
    sid    = "AllowGitHubExporterEncryptOnly"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.github_source_exporter.arn]
    }

    actions = [
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey"
    ]

    resources = ["*"]
  }

  statement {
    sid    = "AllowValidationLambdaUseKey"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.validation_lambda.arn]
    }

    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey"
    ]

    resources = ["*"]
  }
}

resource "aws_s3_bucket" "ingestion" {
  bucket              = var.ingestion_bucket_name
  object_lock_enabled = true
  tags                = var.tags
}

resource "aws_s3_bucket_versioning" "ingestion" {
  bucket = aws_s3_bucket.ingestion.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "ingestion" {
  bucket = aws_s3_bucket.ingestion.id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.object_lock_retention_days
    }
  }
}

resource "aws_s3_bucket_public_access_block" "ingestion" {
  bucket                  = aws_s3_bucket.ingestion.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ingestion" {
  bucket = aws_s3_bucket.ingestion.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.source_ingestion.arn
      sse_algorithm     = "aws:kms"
    }

    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket" "validated" {
  bucket              = var.validated_bucket_name
  object_lock_enabled = true
  tags                = merge(var.tags, { Stage = "Validated" })
}

resource "aws_s3_bucket_versioning" "validated" {
  bucket = aws_s3_bucket.validated.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "validated" {
  bucket = aws_s3_bucket.validated.id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = var.object_lock_retention_days
    }
  }
}

resource "aws_s3_bucket_public_access_block" "validated" {
  bucket                  = aws_s3_bucket.validated.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "validated" {
  bucket = aws_s3_bucket.validated.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.source_ingestion.arn
      sse_algorithm     = "aws:kms"
    }

    bucket_key_enabled = true
  }
}

data "aws_iam_policy_document" "common_bucket_policy" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.ingestion.arn,
      "${aws_s3_bucket.ingestion.arn}/*",
      aws_s3_bucket.validated.arn,
      "${aws_s3_bucket.validated.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "DenyUnencryptedUploads"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:PutObject"]

    resources = [
      "${aws_s3_bucket.ingestion.arn}/*",
      "${aws_s3_bucket.validated.arn}/*"
    ]

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  statement {
    sid    = "DenyWrongKmsKey"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:PutObject"]

    resources = [
      "${aws_s3_bucket.ingestion.arn}/*",
      "${aws_s3_bucket.validated.arn}/*"
    ]

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [aws_kms_key.source_ingestion.arn]
    }
  }
}

data "aws_iam_policy_document" "ingestion_bucket_policy" {
  source_policy_documents = [data.aws_iam_policy_document.common_bucket_policy.json]

  statement {
    sid    = "DenyDeleteFromIngestion"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:PutBucketVersioning",
      "s3:PutObjectRetention",
      "s3:BypassGovernanceRetention"
    ]

    resources = [
      aws_s3_bucket.ingestion.arn,
      "${aws_s3_bucket.ingestion.arn}/*"
    ]
  }
}

resource "aws_s3_bucket_policy" "ingestion" {
  bucket = aws_s3_bucket.ingestion.id
  policy = data.aws_iam_policy_document.ingestion_bucket_policy.json
}

resource "aws_s3_bucket_policy" "validated" {
  bucket = aws_s3_bucket.validated.id
  policy = data.aws_iam_policy_document.common_bucket_policy.json
}

data "aws_iam_policy_document" "github_source_exporter_permissions" {
  statement {
    sid    = "WriteOnlyToLandingPrefix"
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:PutObjectTagging"
    ]

    resources = [
      "${aws_s3_bucket.ingestion.arn}/landing/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [aws_kms_key.source_ingestion.arn]
    }
  }

  statement {
    sid    = "KmsEncryptOnly"
    effect = "Allow"

    actions = [
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey"
    ]

    resources = [aws_kms_key.source_ingestion.arn]
  }
}

resource "aws_iam_policy" "github_source_exporter" {
  name   = "GitHubSourceExportToAISecurityLab"
  policy = data.aws_iam_policy_document.github_source_exporter_permissions.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "github_source_exporter" {
  role       = aws_iam_role.github_source_exporter.name
  policy_arn = aws_iam_policy.github_source_exporter.arn
}

data "aws_iam_policy_document" "validation_lambda_permissions" {
  statement {
    sid    = "ReadLandingWriteValidated"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectTagging",
      "s3:PutObject",
      "s3:PutObjectTagging"
    ]

    resources = [
      "${aws_s3_bucket.ingestion.arn}/landing/*",
      "${aws_s3_bucket.validated.arn}/validated/*",
      "${aws_s3_bucket.validated.arn}/rejected/*"
    ]
  }

  statement {
    sid    = "ListBuckets"
    effect = "Allow"

    actions = ["s3:ListBucket"]

    resources = [
      aws_s3_bucket.ingestion.arn,
      aws_s3_bucket.validated.arn
    ]
  }

  statement {
    sid    = "KmsUse"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey"
    ]

    resources = [aws_kms_key.source_ingestion.arn]
  }

  statement {
    sid    = "LambdaLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "validation_lambda" {
  name   = "AISecurityLabSourceIngestionValidator"
  policy = data.aws_iam_policy_document.validation_lambda_permissions.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "validation_lambda" {
  role       = aws_iam_role.validation_lambda.name
  policy_arn = aws_iam_policy.validation_lambda.arn
}

resource "aws_cloudwatch_log_group" "validation_lambda" {
  name              = "/aws/lambda/ai-security-lab-source-ingestion-validator"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.source_ingestion.arn
  tags              = var.tags
}

data "archive_file" "validator_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/validator.py"
  output_path = "${path.module}/lambda/validator.zip"
}

resource "aws_lambda_function" "validator" {
  function_name    = "ai-security-lab-source-ingestion-validator"
  role             = aws_iam_role.validation_lambda.arn
  handler          = "validator.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.validator_zip.output_path
  source_code_hash = data.archive_file.validator_zip.output_base64sha256
  timeout          = 120
  memory_size      = 512
  kms_key_arn      = aws_kms_key.source_ingestion.arn

  environment {
    variables = {
      INGESTION_BUCKET = aws_s3_bucket.ingestion.bucket
      VALIDATED_BUCKET = aws_s3_bucket.validated.bucket
      KMS_KEY_ARN      = aws_kms_key.source_ingestion.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.validation_lambda]
  tags       = var.tags
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.validator.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.ingestion.arn
}

resource "aws_s3_bucket_notification" "ingestion" {
  bucket = aws_s3_bucket.ingestion.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.validator.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "landing/"
    filter_suffix       = "metadata.json"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}
