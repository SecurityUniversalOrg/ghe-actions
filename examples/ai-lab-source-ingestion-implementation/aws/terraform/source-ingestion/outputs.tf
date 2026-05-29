output "ingestion_bucket_name" {
  value = aws_s3_bucket.ingestion.bucket
}

output "validated_bucket_name" {
  value = aws_s3_bucket.validated.bucket
}

output "kms_key_arn" {
  value = aws_kms_key.source_ingestion.arn
}

output "github_source_export_role_arn" {
  value = aws_iam_role.github_source_exporter.arn
}

output "validation_lambda_name" {
  value = aws_lambda_function.validator.function_name
}
