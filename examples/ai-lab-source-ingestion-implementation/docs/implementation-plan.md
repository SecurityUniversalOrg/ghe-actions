# Detailed Implementation Plan: Source Code Ingestion into AI Security Lab

## Objective

Implement a hardened, auditable, one-way ingestion pattern that allows selected source code repositories to be safely copied into the segmented AI Security Lab without granting the lab direct access to production GitHub, production secrets, production runners, or production cloud environments.

## Target Architecture

```text
Approved Production Repo
  -> GitHub Actions workflow_dispatch / schedule
  -> Read-only checkout
  -> Secret scanning and file filtering
  -> Git bundle and source tarball
  -> Metadata JSON and SHA256 manifest
  -> Sigstore/cosign signature
  -> AWS OIDC AssumeRole
  -> S3 ingestion bucket with Object Lock and SSE-KMS
  -> Lambda package validation
  -> Validated bucket/prefix
  -> AI Lab analysis bucket or lab-owned repo mirror
```

## Implementation Phases

### Phase 1: AWS Ingestion Foundation

1. Deploy the `source-ingestion` Terraform root module in the dedicated lab ingestion account.
2. Create a KMS key dedicated to source ingestion.
3. Create an S3 ingestion landing bucket with versioning and Object Lock.
4. Create an S3 validated bucket with versioning and Object Lock.
5. Configure bucket policies that deny insecure transport, unencrypted uploads, wrong KMS keys, delete operations, and public exposure.
6. Configure GitHub OIDC provider and role trust scoped to approved repositories and branches.
7. Configure validation Lambda permissions with read access to landing and write access to validated/rejected prefixes.
8. Enable CloudTrail data events for the ingestion bucket in the broader lab logging baseline.

### Phase 2: GitHub Export Workflow

1. Add `export-source-to-ai-lab.yml` to an approved repository or publish as a reusable workflow.
2. Set repository variables for the ingestion role ARN, bucket, region, and KMS key.
3. Validate the repository against an allowlist.
4. Perform read-only checkout with `persist-credentials: false`.
5. Remove remote origin from exported copy before packaging.
6. Run secret scanning before export.
7. Exclude sensitive files, generated binaries, dependency caches, Terraform state, and local credentials.
8. Generate `source.tar.gz`, `source.bundle`, `metadata.json`, `manifest.sha256`, and signature files.
9. Upload package to the S3 `landing/` prefix.

### Phase 3: Validation and Routing

1. S3 object creation triggers validation Lambda.
2. Lambda validates package structure, metadata, and required artifacts.
3. Enterprise implementation should additionally verify cosign signatures and schema using an approved public key or identity constraint.
4. Valid packages are copied to `validated/`.
5. Invalid packages are copied to `rejected/` with tags explaining rejection.
6. AI Security Lab analysis consumes only validated packages.

### Phase 4: Optional Lab Repo Mirroring

1. Use `source.bundle` to create a non-authoritative lab-owned repository mirror.
2. Push only to lab-owned repos, never back to production.
3. Apply lab repo rulesets, branch protections, and no production secrets.
4. AI remediation PRs target lab mirrors first.
5. Production PRs require a separate human-approved promotion workflow.

## Hardening Requirements

- Read-only GitHub token or GitHub App.
- No production write access.
- No workflow secrets exported.
- Strip `.git/config` remote credentials.
- Exclude `.env`, keys, certs, Terraform state, cloud config, dependency caches, and generated artifacts.
- Run secret scanning before and after transfer.
- Sign exported bundles and manifests.
- Record commit SHA, source repo, branch, run ID, actor, and timestamp.
- Treat lab copies as non-authoritative.
