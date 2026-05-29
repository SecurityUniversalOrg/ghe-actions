#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import sys

REQUIRED = [
    "source.tar.gz",
    "source.bundle",
    "metadata.json",
    "manifest.sha256"
]

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("package_dir")
    args = parser.parse_args()

    package = pathlib.Path(args.package_dir)
    missing = [name for name in REQUIRED if not (package / name).exists()]
    if missing:
        print(f"Missing required files: {missing}", file=sys.stderr)
        return 1

    metadata = json.loads((package / "metadata.json").read_text())
    if metadata.get("artifact_type") != "source-code-snapshot":
        print("Invalid artifact_type", file=sys.stderr)
        return 1

    if metadata.get("non_authoritative_copy") is not True:
        print("Package must be marked non_authoritative_copy=true", file=sys.stderr)
        return 1

    manifest_lines = (package / "manifest.sha256").read_text().splitlines()
    for line in manifest_lines:
        expected, name = line.split(maxsplit=1)
        actual = sha256(package / name)
        if expected != actual:
            print(f"Checksum mismatch: {name}", file=sys.stderr)
            return 1

    print("Package validation passed")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
