#!/usr/bin/env bash
set -euo pipefail

SOURCE_BUNDLE="${1:?Usage: mirror-to-lab-repo.sh source.bundle lab_repo_url}"
LAB_REPO_URL="${2:?Usage: mirror-to-lab-repo.sh source.bundle lab_repo_url}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

git clone "${SOURCE_BUNDLE}" "${WORKDIR}/repo"
cd "${WORKDIR}/repo"

git remote remove origin || true
git remote add lab "${LAB_REPO_URL}"

git push lab HEAD:refs/heads/lab-mirror --force
