variable "aws_region" {
  description = "AWS region for source ingestion resources."
  type        = string
  default     = "us-east-1"
}

variable "ingestion_bucket_name" {
  description = "S3 bucket for source ingestion landing packages. Must be globally unique."
  type        = string
}

variable "validated_bucket_name" {
  description = "S3 bucket for validated source packages. Must be globally unique."
  type        = string
}

variable "github_org" {
  description = "GitHub organization that is allowed to assume the ingestion role."
  type        = string
}

variable "allowed_repositories" {
  description = "List of repositories allowed to assume the ingestion role, repo name only."
  type        = list(string)
}

variable "allowed_branches" {
  description = "Allowed branches for source export."
  type        = list(string)
  default     = ["main", "master"]
}

variable "object_lock_retention_days" {
  description = "Default Object Lock retention in days for ingestion evidence."
  type        = number
  default     = 365
}

variable "kms_admin_role_arns" {
  description = "Role ARNs allowed to administer the KMS key."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Standard tags."
  type        = map(string)
  default = {
    Program      = "AI Security Lab"
    Component    = "Source Ingestion"
    DataClass    = "Internal"
    Owner        = "Security"
    ManagedBy    = "Terraform"
    SecurityZone = "Ingestion"
  }
}
