import json
import os
import urllib.parse
import boto3

s3 = boto3.client("s3")

REQUIRED_METADATA_FIELDS = [
    "source_repo",
    "source_branch",
    "commit_sha",
    "export_timestamp",
    "github_run_id",
    "artifact_type",
    "sha256_manifest",
    "non_authoritative_copy"
]

REQUIRED_PACKAGE_FILES = [
    "metadata.json",
    "manifest.sha256",
    "source.bundle",
    "source.tar.gz"
]


def get_object_text(bucket, key):
    response = s3.get_object(Bucket=bucket, Key=key)
    return response["Body"].read().decode("utf-8")


def copy_object(src_bucket, src_key, dst_bucket, dst_key, tags):
    tagging = "&".join([f"{k}={urllib.parse.quote(str(v))}" for k, v in tags.items()])
    s3.copy_object(
        Bucket=dst_bucket,
        Key=dst_key,
        CopySource={"Bucket": src_bucket, "Key": src_key},
        ServerSideEncryption="aws:kms",
        SSEKMSKeyId=os.environ["KMS_KEY_ARN"],
        TaggingDirective="REPLACE",
        Tagging=tagging,
    )


def reject(src_bucket, src_key, reason):
    dst_bucket = os.environ["VALIDATED_BUCKET"]
    dst_key = "rejected/" + src_key.replace("landing/", "", 1)
    copy_object(src_bucket, src_key, dst_bucket, dst_key, {
        "ValidationStatus": "Rejected",
        "Reason": reason[:128]
    })


def approve(src_bucket, src_key):
    dst_bucket = os.environ["VALIDATED_BUCKET"]
    dst_key = "validated/" + src_key.replace("landing/", "", 1)
    copy_object(src_bucket, src_key, dst_bucket, dst_key, {
        "ValidationStatus": "Validated"
    })


def handler(event, context):
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

        if not key.endswith("metadata.json"):
            continue

        prefix = key.rsplit("/", 1)[0] + "/"

        try:
            metadata = json.loads(get_object_text(bucket, key))
        except Exception as exc:
            reject(bucket, key, f"Invalid metadata JSON: {exc}")
            continue

        missing = [field for field in REQUIRED_METADATA_FIELDS if field not in metadata]
        if missing:
            reject(bucket, key, f"Missing metadata fields: {missing}")
            continue

        if metadata.get("artifact_type") != "source-code-snapshot":
            reject(bucket, key, "Unsupported artifact_type")
            continue

        if metadata.get("non_authoritative_copy") is not True:
            reject(bucket, key, "Package must be marked non_authoritative_copy=true")
            continue

        listed = s3.list_objects_v2(Bucket=bucket, Prefix=prefix)
        keys = [item["Key"] for item in listed.get("Contents", [])]

        required_keys = [prefix + item for item in REQUIRED_PACKAGE_FILES]
        missing_files = [item for item in required_keys if item not in keys]
        if missing_files:
            reject(bucket, key, f"Missing package files: {missing_files}")
            continue

        # Minimal enterprise baseline. Add cosign verification, malware scanning,
        # JSON Schema validation, and Macie classification before production use.
        for package_key in keys:
            approve(bucket, package_key)

    return {"statusCode": 200, "body": "validation complete"}
