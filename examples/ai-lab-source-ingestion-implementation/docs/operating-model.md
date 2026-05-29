# Source Ingestion Operating Model

## Ownership

| Function | Owner |
|---|---|
| Repository approval | Security |
| AWS ingestion account and KMS | IT Operations / Cloud Platform |
| Export workflow implementation | AI Engineering / DevSecOps |
| Data classification | Security / Compliance |
| AI analysis workflows | AI Engineering |
| Production remediation promotion | Application Owner + Security |

## Standard Workflow

1. Application team requests source ingestion.
2. Security validates data classification and business justification.
3. Repository is added to the allowlist.
4. GitHub OIDC trust is updated to include repo and branch.
5. Initial manual export is run.
6. Validation Lambda classifies package as validated or rejected.
7. AI analysis consumes validated snapshot.
8. Findings are published in lab dashboards or lab GitHub Issues.
9. Any production-facing issue/PR requires separate human approval.

## Exception Requirements

Exceptions must include repository, branch, data classification, reason, expiration, approver, and compensating controls.
