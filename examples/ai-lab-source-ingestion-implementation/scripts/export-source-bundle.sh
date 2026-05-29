#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="${1:-export-output/package}"
EXCLUSIONS_FILE="${2:-config/file-exclusions.txt}"

mkdir -p "${OUTPUT_DIR}"

git config --unset-all http.https://github.com/.extraheader || true
git remote remove origin || true

tar --exclude-vcs --exclude-from="${EXCLUSIONS_FILE}" -czf "${OUTPUT_DIR}/source.tar.gz" .
git bundle create "${OUTPUT_DIR}/source.bundle" HEAD

cat > "${OUTPUT_DIR}/metadata.json" <<META
{
  "artifact_type": "source-code-snapshot",
  "source_repo": "${GITHUB_REPOSITORY:-unknown}",
  "source_branch": "${GITHUB_REF_NAME:-unknown}",
  "commit_sha": "${GITHUB_SHA:-$(git rev-parse HEAD)}",
  "export_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "github_run_id": "${GITHUB_RUN_ID:-local}",
  "github_workflow": "${GITHUB_WORKFLOW:-local}",
  "github_actor": "${GITHUB_ACTOR:-local}",
  "sha256_manifest": "manifest.sha256",
  "non_authoritative_copy": true
}
META

(cd "${OUTPUT_DIR}" && sha256sum * > manifest.sha256)
