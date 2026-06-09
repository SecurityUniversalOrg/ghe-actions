#!/usr/bin/env python3

import argparse
import csv
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


OUTPUT_FIELDS = [
    "repo",
    "branch",
    "total_files",
    "blank_lines",
    "comment_lines",
    "code_lines",
    "last_scanned_utc",
    "status",
    "error",
]


def run_command(command, cwd=None, check=True):
    result = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    if check and result.returncode != 0:
        raise RuntimeError(
            f"Command failed: {' '.join(command)}\n"
            f"STDOUT:\n{result.stdout}\n"
            f"STDERR:\n{result.stderr}"
        )

    return result


def safe_repo_dir_name(repo: str, branch: str) -> str:
    return (
        repo.replace("/", "__")
        .replace(":", "_")
        .replace("\\", "_")
        .replace(" ", "_")
        + "__"
        + branch.replace("/", "__").replace("\\", "_").replace(" ", "_")
    )


def load_existing_report(output_path: Path):
    rows_by_repo = {}

    if not output_path.exists():
        return rows_by_repo

    with output_path.open(newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for row in reader:
            repo = row.get("repo", "").strip()
            if repo:
                rows_by_repo[repo] = row

    return rows_by_repo


def clone_repo(repo: str, branch: str, destination: Path, token: str):
    if destination.exists():
        shutil.rmtree(destination)

    clone_url = f"https://github.com/{repo}.git"

    if token:
        clone_url = f"https://x-access-token:{token}@github.com/{repo}.git"

    command = [
        "git",
        "clone",
        "--depth",
        "1",
        "--single-branch",
        "--branch",
        branch,
        clone_url,
        str(destination),
    ]

    run_command(command)


def run_cloc(repo_path: Path):
    cloc_output = repo_path / "cloc.json"

    exclude_dirs = [
        ".git",
        "node_modules",
        "vendor",
        "dist",
        "build",
        ".terraform",
        ".venv",
        "venv",
        "__pycache__",
    ]

    command = [
        "cloc",
        str(repo_path),
        "--json",
        f"--exclude-dir={','.join(exclude_dirs)}",
        f"--out={cloc_output}",
    ]

    run_command(command)

    with cloc_output.open(encoding="utf-8") as f:
        data = json.load(f)

    total = data.get("SUM", {})

    return {
        "total_files": str(total.get("nFiles", 0)),
        "blank_lines": str(total.get("blank", 0)),
        "comment_lines": str(total.get("comment", 0)),
        "code_lines": str(total.get("code", 0)),
    }


def normalize_row(repo: str, branch: str, status: str, error: str = "", totals=None):
    totals = totals or {}

    return {
        "repo": repo,
        "branch": branch,
        "total_files": totals.get("total_files", "0"),
        "blank_lines": totals.get("blank_lines", "0"),
        "comment_lines": totals.get("comment_lines", "0"),
        "code_lines": totals.get("code_lines", "0"),
        "last_scanned_utc": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "status": status,
        "error": error,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="Input CSV with repo and branch columns")
    parser.add_argument("--output", required=True, help="Master output CSV to update")
    parser.add_argument("--work-dir", required=True, help="Temporary clone working directory")
    parser.add_argument("--token", default="", help="GitHub token with read access to target repos")
    args = parser.parse_args()

    input_path = Path(args.input)
    output_path = Path(args.output)
    work_dir = Path(args.work_dir)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    work_dir.mkdir(parents=True, exist_ok=True)

    existing_rows = load_existing_report(output_path)

    with input_path.open(newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)

        for input_row in reader:
            repo = (input_row.get("repo") or "").strip()
            branch = (input_row.get("branch") or "").strip()

            if not repo or not branch:
                continue

            print(f"Scanning {repo}@{branch}")

            repo_dir = work_dir / safe_repo_dir_name(repo, branch)

            try:
                clone_repo(repo, branch, repo_dir, args.token)
                totals = run_cloc(repo_dir)
                existing_rows[repo] = normalize_row(
                    repo=repo,
                    branch=branch,
                    status="success",
                    totals=totals,
                )
                print(f"Completed {repo}@{branch}: {totals['code_lines']} code lines")

            except Exception as exc:
                error_message = str(exc).replace("\n", " ")[:500]
                existing_rows[repo] = normalize_row(
                    repo=repo,
                    branch=branch,
                    status="failed",
                    error=error_message,
                )
                print(f"Failed {repo}@{branch}: {error_message}", file=sys.stderr)

            finally:
                if repo_dir.exists():
                    shutil.rmtree(repo_dir)

    sorted_rows = sorted(existing_rows.values(), key=lambda row: row.get("repo", "").lower())

    with output_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=OUTPUT_FIELDS)
        writer.writeheader()
        for row in sorted_rows:
            writer.writerow({field: row.get(field, "") for field in OUTPUT_FIELDS})

    print(f"Updated {output_path}")


if __name__ == "__main__":
    main()