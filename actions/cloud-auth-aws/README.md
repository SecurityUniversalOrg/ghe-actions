# Setting up Identity

## Step 1 — Create AWS OIDC Identity Provider
### AWS CLI
```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```
### Example Output:
```bash
{
    "OpenIDConnectProviderArn": "arn:aws:iam::327784329945:oidc-provider/token.actions.githubusercontent.com"
}
```

## Step 2 - Create IAM Role for GitHub
Example: Terraform-Deploy-Dev
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:ORG/REPO:ref:refs/heads/main"
        }
      }
    }
  ]
}
```
#### Important FedRAMP Hardening
You SHOULD restrict:
* Repository
* Branch
* Environment
* Pull Request vs main
* Optionally tag-based conditions

Example more restrictive:
```ruby
repo:ORG/REPO:environment:tf-apply-prod
```

## Step 3 - Attach Least Privilege Policy
Example for Terraform deploying network infra:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:*",
        "iam:PassRole"
      ],
      "Resource": "*"
    }
  ]
}
```
#### For FedRAMP:
* Scope to specific ARNs
* Avoid *
* Separate roles per environment

## Step 4 - Store Variables in GitHub
#### Go to:
Repo --> Settings --> Variables --> Actions
#### Create:
```nginx
AWS_REGION
AWS_ROLE_TO_ASSUME
```
#### Example:
```ruby
AWS_REGION = us-gov-west-1
AWS_ROLE_TO_ASSUME = arn:aws-us-gov:iam::123456789012:role/Terraform-Deploy-Dev
```

## Step 5 - Terraform Provider Config
```hcl
provider "aws" {
  region = var.region
}
```