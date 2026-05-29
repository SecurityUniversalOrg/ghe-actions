# AI Security Lab Source Code Ingestion Implementation

This implementation provides a hardened early-phase pattern for bringing source code into a segmented AWS AI Security Lab.

## Pattern

```text
Production GitHub / GHES / GHEC Repository
  -> Read-only export workflow
  -> Secret scan / file allowlist / binary exclusion
  -> Git bundle + tarball generation
  -> SHA256 manifest
  -> Cosign signing / optional GPG signing
  -> S3 Object Lock ingestion bucket
  -> EventBridge / Lambda validation
  -> Approved copy into lab analysis bucket or lab-owned repo mirror
```

## Design Goals

- No production write access.
- No production secrets exported.
- No direct lab access back into production GitHub.
- Point-in-time signed repository snapshots.
- Repo-level allowlisting.
- Immutable ingestion evidence.
- Strong KMS encryption.
- S3 Object Lock retention.
- Bucket policies that prevent public access, insecure transport, and unencrypted writes.
- Validation before lab analysis.
- Lab copy is non-authoritative.

## Included Files

```text
aws/terraform/source-ingestion/     Terraform resources for S3, KMS, OIDC, IAM, Lambda validation
aws/terraform/source-ingestion/lambda/validator.py
github/workflows/export-source-to-ai-lab.yml
config/repo-allowlist.yaml
config/file-exclusions.txt
config/ingestion-metadata.schema.json
scripts/export-source-bundle.sh
scripts/validate-ingestion-package.py
scripts/mirror-to-lab-repo.sh
policies/iam/*.json
policies/s3/*.json
docs/implementation-plan.md
docs/operating-model.md
docs/data-flow.md
```
