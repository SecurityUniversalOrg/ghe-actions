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
    "OpenIDConnectProviderArn": "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
}
```

## Step 2 - Create IAM Role for GitHub
#### Example: Terraform-Deploy-Dev
Create `trust-policy.json`:
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
#### Create the Role
```bash
aws iam create-role \
  --role-name ${ROLE_NAME} \
  --assume-role-policy-document file://trust-policy.json \
  --description "GitHub OIDC Terraform deploy role (dev)"
```
#### Verify
```bash
aws iam get-role --role-name ${ROLE_NAME}
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
#### Example for Terraform deploying network in
Create `terraform-dev-policy.json`

Example: EC2 + IAM PassRole minimal sample
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2Permissions",
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*",
        "ec2:CreateVpc",
        "ec2:DeleteVpc",
        "ec2:CreateSubnet",
        "ec2:DeleteSubnet"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowPassRole",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws-us-gov:iam::123456789012:role/SomeEC2InstanceRole"
    }
  ]
}
```
#### In Production:
* Replace `*` with scoped ARNs
* Separate networking, IAM, compute into different roles if possible

### Create Policy in AWS
```bash
aws iam create-policy \
  --policy-name Terraform-Deploy-Dev-Policy \
  --policy-document file://terraform-dev-policy.json
```
Output will include:
```json
"Arn": "arn:aws-us-gov:iam::123456789012:policy/Terraform-Deploy-Dev-Policy"
```
#### Save this ARN

### Attach Policy to Role
```bash
aws iam attach-role-policy \
  --role-name ${ROLE_NAME} \
  --policy-arn arn:aws-us-gov:iam::${ACCOUNT_ID}:policy/Terraform-Deploy-Dev-Policy
```
Verify:
```bash
aws iam list-attached-role-policies --role-name ${ROLE_NAME}
```

### For FedRAMP:
* Scope to specific ARNs
* Avoid *
* Separate roles per environment

##### Only allow assume role from specific GitHub environment:
```ruby
repo:ORG/REPO:environment:tf-apply-prod
```

##### Restrict to tags:
```json
"Condition": {
  "StringEquals": {
    "aws:RequestTag/Environment": "Dev"
  }
}
```



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