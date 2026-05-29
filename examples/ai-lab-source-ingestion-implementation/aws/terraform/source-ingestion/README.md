# AI Security Lab Source Ingestion Terraform

## Overview

This Terraform module deploys the AWS infrastructure required to securely ingest source code snapshots from approved GitHub, GitHub Enterprise Server, or GitHub Enterprise Cloud repositories into a segmented AI Security Lab.

The design follows a **one-way, read-only export model**:

```text
Approved Production GitHub Repository
  -> GitHub Actions read-only export workflow
  -> Secret scan / file filtering / package signing
  -> GitHub OIDC assume role
  -> S3 ingestion bucket with Object Lock and SSE-KMS
  -> S3 event notification
  -> Lambda validation workflow
  -> Validated S3 bucket for AI Security Lab analysis
```

The AI Security Lab should not directly connect back into production source control systems. Instead, approved repositories export signed, point-in-time source snapshots into a controlled AWS ingestion boundary.

---

## Terraform Resources Created

| Resource Area | Purpose |
|---|---|
| S3 ingestion bucket | Landing zone for raw source export packages |
| S3 validated bucket | Stores validated source packages approved for lab analysis |
| S3 Object Lock | Provides write-once-read-many retention controls |
| SSE-KMS encryption | Encrypts all source packages using a customer-managed KMS key |
| KMS key | Dedicated encryption key for source ingestion data |
| GitHub OIDC provider | Enables GitHub Actions to assume AWS roles without static credentials |
| GitHub source export IAM role | Write-only role used by approved GitHub repositories |
| Lambda validation role | Role used by the package validation Lambda function |
| S3 bucket policies | Enforces TLS, KMS encryption, delete protection, and upload restrictions |
| S3 event notification | Triggers validation when new packages are uploaded |

---

## Security Objectives

This Terraform is designed to enforce the following controls:

1. No long-lived AWS credentials in GitHub.
2. No production write access from the lab.
3. No direct lab access to production repositories.
4. Write-only source export into the ingestion bucket.
5. KMS encryption for all source packages.
6. Object Lock retention to prevent tampering or deletion.
7. Repository and branch allowlisting through GitHub OIDC trust conditions.
8. Validation before packages are promoted for AI analysis.
9. Separation between raw landing data and validated analysis data.
10. CloudTrail-auditable access to all ingestion resources.

---

## Architecture

```text
+-------------------------------+
| Approved GitHub Repository    |
| contents: read                |
| id-token: write               |
+---------------+---------------+
                |
                | GitHub OIDC
                v
+-------------------------------+
| IAM Role                      |
| GitHubSourceExportToAISecurityLab |
| Write-only to S3 landing      |
+---------------+---------------+
                |
                | PutObject with SSE-KMS
                v
+-------------------------------+
| S3 Ingestion Bucket           |
| Prefix: landing/              |
| Object Lock enabled           |
| Versioning enabled            |
| SSE-KMS required              |
+---------------+---------------+
                |
                | ObjectCreated event
                v
+-------------------------------+
| Lambda Validator              |
| Validates metadata/package    |
| Copies to validated/rejected  |
+---------------+---------------+
                |
                v
+-------------------------------+
| S3 Validated Bucket           |
| Prefix: validated/ or rejected/ |
| Used by AI Security Lab       |
+-------------------------------+
```

---

# Resource Details

## 1. S3 Ingestion Bucket

### Purpose

The S3 ingestion bucket is the initial landing zone for source code export packages uploaded from approved GitHub repositories.

Example package layout:

```text
landing/
  ExampleOrg/
    example-app/
      main/
        <commit-sha>/
          <github-run-id>/
            source.tar.gz
            source.bundle
            metadata.json
            manifest.sha256
            manifest.sha256.sig
            manifest.sha256.pem
            secret-scan-results.json
```

### Key Controls

The bucket is configured with:

- Versioning enabled
- Object Lock enabled
- Default retention period
- SSE-KMS encryption
- Block Public Access
- Bucket policy enforcement
- Delete protection through explicit deny statements
- Upload restrictions requiring TLS and KMS encryption

### Terraform Resources

```hcl
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

resource "aws_s3_bucket_public_access_block" "ingestion" {
  bucket                  = aws_s3_bucket.ingestion.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

---

## 2. S3 Validated Bucket

### Purpose

The validated bucket stores packages after validation has completed.

Validated packages are copied to:

```text
validated/
```

Rejected packages are copied to:

```text
rejected/
```

The validated bucket acts as a safer source for downstream AI Security Lab analysis workflows.

### Why Separate Buckets?

Using a separate validated bucket provides a clean security boundary between:

| Bucket | Purpose |
|---|---|
| Ingestion bucket | Raw source export landing zone |
| Validated bucket | Packages that passed validation checks |

This prevents AI analysis workflows from accidentally processing unvalidated, malformed, unsigned, or unexpected packages.

### Key Controls

The validated bucket uses:

- Versioning
- Object Lock
- SSE-KMS encryption
- Block Public Access
- TLS-only bucket policies
- KMS-only write policies

---

## 3. S3 Object Lock

### Purpose

S3 Object Lock provides write-once-read-many style protection for uploaded source packages and evidence.

This helps prevent:

- Accidental deletion
- Malicious deletion
- Evidence tampering
- Overwriting source snapshots
- Removal of rejected packages before review

### Recommended Retention

| Data Type | Suggested Retention |
|---|---|
| Raw source snapshots | 90-365 days |
| Validated source snapshots | 90-365 days |
| High-risk analysis evidence | 365+ days |
| Compliance evidence | 3-7 years depending on policy |

### Terraform Configuration

```hcl
resource "aws_s3_bucket_object_lock_configuration" "ingestion" {
  bucket = aws_s3_bucket.ingestion.id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.object_lock_retention_days
    }
  }
}
```

### Recommended Modes

| Mode | Usage |
|---|---|
| Governance | Lower environments or operational flexibility |
| Compliance | Stronger protection for audit/evidence retention |

For the ingestion bucket, **Compliance mode** is recommended when source exports are treated as audit evidence.

---

## 4. SSE-KMS Encryption

### Purpose

All source packages are encrypted using server-side encryption with a customer-managed KMS key.

This provides:

- Centralized key control
- Key rotation
- Access auditing
- Explicit separation from default AWS-managed keys
- Ability to enforce encryption through S3 bucket policies

### Terraform Configuration

```hcl
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
```

### Upload Enforcement

The bucket policy denies uploads that do not specify:

```text
x-amz-server-side-encryption: aws:kms
```

and the expected KMS key:

```text
x-amz-server-side-encryption-aws-kms-key-id: <source-ingestion-kms-key-arn>
```

---

## 5. KMS Key

### Purpose

A dedicated KMS key protects source ingestion data.

The key is used by:

- GitHub source export IAM role
- Lambda validation function
- S3 ingestion bucket
- S3 validated bucket
- CloudWatch Logs for validation activity, if configured

### Key Controls

Recommended KMS hardening:

- Enable key rotation
- Use least-privilege key policy
- Allow GitHub export role to encrypt only
- Allow validation Lambda to decrypt and re-encrypt
- Limit key administration to approved security/cloud roles
- Monitor KMS usage through CloudTrail

### Terraform Configuration

```hcl
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
```

### GitHub Exporter KMS Permissions

The GitHub source export role should only be able to encrypt data:

```hcl
actions = [
  "kms:Encrypt",
  "kms:GenerateDataKey",
  "kms:DescribeKey"
]
```

It should not have:

```text
kms:Decrypt
```

This prevents the production export workflow from reading source packages back out of the lab ingestion bucket.

---

## 6. GitHub OIDC Provider

### Purpose

The GitHub OIDC provider allows GitHub Actions workflows to assume AWS IAM roles using short-lived credentials.

This avoids storing static AWS access keys in GitHub.

### Terraform Configuration

```hcl
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
  tags            = var.tags
}
```

### Enterprise Hardening Notes

For enterprise rollout:

- Validate the GitHub OIDC thumbprint through change control.
- Scope trust conditions to approved repositories.
- Scope trust conditions to approved branches.
- Use separate roles for different environments or data classifications.
- Avoid wildcard repository trust such as `repo:ORG/*:*` unless there is a compensating control.

---

## 7. GitHub Source Export IAM Role

### Purpose

The GitHub source export role is assumed by approved GitHub repositories through OIDC.

It allows a production repository workflow to upload source export packages to the ingestion bucket.

### Key Design

This role should be **write-only**.

It should allow:

- `s3:PutObject`
- `s3:PutObjectTagging`
- `kms:Encrypt`
- `kms:GenerateDataKey`
- `kms:DescribeKey`

It should not allow:

- `s3:GetObject`
- `s3:ListBucket`
- `s3:DeleteObject`
- `kms:Decrypt`
- Any production AWS permissions
- Any lab administrative permissions

### Trust Policy

The trust policy restricts access to approved repositories and branches.

Example:

```hcl
condition {
  test     = "StringLike"
  variable = "token.actions.githubusercontent.com:sub"
  values   = [
    "repo:ExampleOrg/example-app:ref:refs/heads/main",
    "repo:ExampleOrg/example-api:ref:refs/heads/main"
  ]
}
```

### Terraform Configuration

```hcl
resource "aws_iam_role" "github_source_exporter" {
  name                 = "GitHubSourceExportToAISecurityLab"
  assume_role_policy   = data.aws_iam_policy_document.github_source_exporter_trust.json
  max_session_duration = 3600
  tags                 = var.tags
}
```

### Permission Policy

```hcl
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
}
```

---

## 8. Lambda Validation Role

### Purpose

The Lambda validation role allows the validation function to inspect uploaded packages and copy them to the validated or rejected bucket prefixes.

### Lambda Responsibilities

The validator should check:

- `metadata.json` exists
- Required metadata fields are present
- Artifact type is valid
- `source.tar.gz` exists
- `source.bundle` exists
- `manifest.sha256` exists
- Checksums match
- Signature exists
- Optional signature validation passes
- Secret scan result exists
- Package structure matches expected format

### IAM Permissions

The Lambda role requires:

- Read access to the ingestion bucket landing prefix
- Write access to the validated bucket
- KMS decrypt/encrypt permissions
- CloudWatch Logs permissions

### Terraform Configuration

```hcl
resource "aws_iam_role" "validation_lambda" {
  name               = "AISecurityLabSourceIngestionValidator"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = var.tags
}
```

```hcl
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
```

---

## 9. S3 Bucket Policies

### Purpose

Bucket policies enforce security requirements even if an IAM role is accidentally over-permissioned.

### Required Policy Controls

#### Deny Non-TLS Access

```hcl
condition {
  test     = "Bool"
  variable = "aws:SecureTransport"
  values   = ["false"]
}
```

#### Deny Unencrypted Uploads

```hcl
condition {
  test     = "StringNotEquals"
  variable = "s3:x-amz-server-side-encryption"
  values   = ["aws:kms"]
}
```

#### Deny Wrong KMS Key

```hcl
condition {
  test     = "StringNotEquals"
  variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
  values   = [aws_kms_key.source_ingestion.arn]
}
```

#### Deny Deletes

```hcl
actions = [
  "s3:DeleteObject",
  "s3:DeleteObjectVersion",
  "s3:PutBucketVersioning",
  "s3:PutObjectRetention",
  "s3:BypassGovernanceRetention"
]
```

### Why Bucket Policies Matter

Bucket policies provide a resource-level enforcement point for:

- Encryption
- Transport security
- Delete prevention
- Write restrictions
- Public access prevention
- Organization boundary controls

These controls should exist even when IAM permissions are believed to be correct.

---

## 10. S3 Event Notification to Lambda

### Purpose

The S3 event notification triggers the validation Lambda whenever a new object is uploaded under the `landing/` prefix.

### Terraform Configuration

```hcl
resource "aws_s3_bucket_notification" "ingestion" {
  bucket = aws_s3_bucket.ingestion.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.validator.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "landing/"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}
```

```hcl
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.validator.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.ingestion.arn
}
```

### Validation Flow

```text
Object uploaded to s3://ingestion-bucket/landing/...
  -> S3 sends ObjectCreated event
  -> Lambda validator runs
  -> Lambda validates package metadata and required files
  -> Lambda copies package to validated/ or rejected/
```

---

# Required Variables

| Variable | Description | Example |
|---|---|---|
| `aws_region` | AWS region for ingestion resources | `us-east-1` |
| `ingestion_bucket_name` | Raw landing bucket name | `company-ai-lab-source-ingestion` |
| `validated_bucket_name` | Validated package bucket name | `company-ai-lab-source-validated` |
| `github_org` | GitHub organization name | `ExampleOrg` |
| `allowed_repositories` | Repositories allowed to export source | `["example-app"]` |
| `allowed_branches` | Branches allowed to assume role | `["main"]` |
| `object_lock_retention_days` | Object Lock retention period | `365` |
| `kms_admin_role_arns` | KMS administrator roles | `["arn:aws:iam::123456789012:role/LabSecurityAdmin"]` |
| `tags` | Standard resource tags | See example below |

---

# Example `terraform.tfvars`

```hcl
aws_region            = "us-east-1"
ingestion_bucket_name = "company-ai-security-lab-source-ingestion"
validated_bucket_name = "company-ai-security-lab-source-validated"
github_org           = "CompanyGitHubOrg"

allowed_repositories = [
  "account-management",
  "customer-api",
  "shared-iac"
]

allowed_branches = [
  "main"
]

object_lock_retention_days = 365

kms_admin_role_arns = [
  "arn:aws:iam::111122223333:role/LabSecurityAdmin",
  "arn:aws:iam::111122223333:role/LabCloudPlatformAdmin"
]

tags = {
  Program       = "AI Security Lab"
  Component     = "Source Ingestion"
  DataClass     = "Internal"
  Owner         = "Security"
  ManagedBy     = "Terraform"
  SecurityZone  = "Ingestion"
  CostCenter    = "Security"
}
```

---

# Deployment Steps

## 1. Review and Update Variables

Update `terraform.tfvars` with:

- Real bucket names
- GitHub organization
- Approved repositories
- Approved branches
- KMS admin roles
- Required tags

## 2. Initialize Terraform

```bash
terraform init
```

## 3. Validate Terraform

```bash
terraform fmt -recursive
terraform validate
```

## 4. Review the Plan

```bash
terraform plan -out source-ingestion.tfplan
```

## 5. Apply the Plan

```bash
terraform apply source-ingestion.tfplan
```

## 6. Capture Outputs

```bash
terraform output
```

Important outputs:

- `ingestion_bucket_name`
- `validated_bucket_name`
- `kms_key_arn`
- `github_source_export_role_arn`
- `validation_lambda_name`

---

# GitHub Workflow Integration

The GitHub export workflow should use the Terraform output `github_source_export_role_arn` as the role to assume.

Example GitHub workflow environment variables:

```yaml
env:
  AWS_REGION: us-east-1
  AI_LAB_INGESTION_BUCKET: company-ai-security-lab-source-ingestion
  AI_LAB_INGESTION_ROLE_ARN: arn:aws:iam::111122223333:role/GitHubSourceExportToAISecurityLab
  AI_LAB_KMS_KEY_ARN: arn:aws:kms:us-east-1:111122223333:key/example-key-id
```

The workflow should use GitHub OIDC:

```yaml
permissions:
  contents: read
  id-token: write
```

The workflow should not use static AWS keys.

---

# Package Validation Requirements

Each source package should include:

```text
source.tar.gz
source.bundle
metadata.json
manifest.sha256
manifest.sha256.sig
manifest.sha256.pem
secret-scan-results.json
```

## Required Metadata

```json
{
  "artifact_type": "source-code-snapshot",
  "source_repo": "ExampleOrg/example-app",
  "source_branch": "main",
  "commit_sha": "0000000000000000000000000000000000000000",
  "export_timestamp": "2026-05-28T00:00:00Z",
  "github_run_id": "123456789",
  "github_workflow": "Export Source to AI Security Lab",
  "github_actor": "username",
  "export_reason": "scheduled export",
  "sha256_manifest": "manifest.sha256",
  "non_authoritative_copy": true
}
```

---

# Recommended Enhancements

For production enterprise use, add:

1. CloudTrail S3 data events for both buckets.
2. Macie classification jobs on landing and validated buckets.
3. EventBridge routing for validation success/failure.
4. SNS notifications to Security and AI Engineering.
5. DynamoDB ingestion registry for package metadata.
6. Code signing verification in the Lambda validator.
7. Cosign certificate identity validation.
8. AV/malware scanning before promotion.
9. OPA policy validation for metadata and repo allowlists.
10. Step Functions approval workflow before analysis.
11. Separate buckets by data classification.
12. S3 replication into isolated lab analysis accounts.
13. Object tagging for data classification and retention.
14. Automated rejection for packages containing secrets.
15. CloudWatch alarms for unusual upload volume or failed validation.

---

# Operational Responsibilities

| Team | Responsibilities |
|---|---|
| Security | Approves repositories, data classifications, retention, validation rules, and exceptions |
| Cloud Platform / IT Operations | Owns Terraform, AWS accounts, IAM, KMS, S3, and logging |
| AI Engineering | Owns downstream AI analysis workflows and validated package consumption |
| Application Teams | Approve repository export and review generated security findings |
| Compliance | Reviews retention, evidence, and regulated data handling |

---

# Failure Handling

| Failure | Expected Action |
|---|---|
| Metadata missing | Copy package to `rejected/` |
| Manifest missing | Copy package to `rejected/` |
| Checksum mismatch | Copy package to `rejected/` |
| Signature missing | Copy package to `rejected/` |
| Secret scan findings present | Reject package and notify Security |
| Unauthorized repo | GitHub workflow should fail before upload |
| Wrong KMS key | S3 bucket policy denies upload |
| Non-TLS request | S3 bucket policy denies request |
| Delete attempt | S3 bucket policy denies request |

---

# Security Review Checklist

Before production use, verify:

- [ ] Bucket names are unique and approved.
- [ ] Object Lock mode and retention meet policy.
- [ ] KMS key policy is least privilege.
- [ ] GitHub OIDC trust is scoped to approved repositories.
- [ ] GitHub OIDC trust is scoped to approved branches.
- [ ] GitHub export role has no read/list/delete permissions.
- [ ] GitHub export role does not have `kms:Decrypt`.
- [ ] S3 bucket policies deny non-TLS access.
- [ ] S3 bucket policies deny unencrypted uploads.
- [ ] S3 bucket policies deny wrong KMS key usage.
- [ ] S3 bucket policies deny deletes.
- [ ] Lambda role is scoped to required prefixes.
- [ ] Validation Lambda logs to encrypted CloudWatch Logs.
- [ ] S3 event notification is restricted to `landing/`.
- [ ] Secret scanning is performed before upload.
- [ ] Package signing is enabled.
- [ ] Manifest validation is enabled.
- [ ] Rejected packages are preserved for review.
- [ ] AI analysis reads only from validated data.
- [ ] Lab outputs require approval before production use.

---

# Important Design Constraint

The AI Security Lab copy of source code must always be treated as:

```text
non-authoritative
read-only
point-in-time
segmented
controlled by Security approval
```

The lab should never become the system of record for application source code, and AI-generated remediations should not be written directly back to production repositories without human review and normal change-control processes.
