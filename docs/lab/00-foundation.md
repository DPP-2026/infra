# Lab 0 — Foundation: Repo Layout, Provider, Backend

**Goal:** Create the skeleton of the infra repo and configure Terraform to talk to AWS and store state in S3.

**Pattern:** Start with the standard Terraform files — `provider.tf`, `backend.tf`, `variables.tf`, `outputs.tf`, and `main.tf`.

---

## Step 0.1 — Create the repository

```bash
mkdir zen-infra && cd zen-infra
git init
mkdir -p envs/dev modules
```

You will add modules one lab at a time. For now, only `envs/dev/` needs files.

---

## Step 0.2 — Create the S3 state bucket (one-time, manual)

Terraform needs a place to store state **before** you can run `terraform init` with a remote backend.

Replace `YOUR-UNIQUE-SUFFIX` with your GitHub username or cohort ID:

```bash
export STATE_BUCKET="zen-pharma-terraform-state-YOUR-UNIQUE-SUFFIX"
export AWS_REGION="us-east-1"

aws s3api create-bucket \
  --bucket "$STATE_BUCKET" \
  --region "$AWS_REGION"

aws s3api put-bucket-versioning \
  --bucket "$STATE_BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$STATE_BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": { "SSEAlgorithm": "AES256" }
    }]
  }'

aws s3api put-public-access-block \
  --bucket "$STATE_BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

**Why manual?** Chicken-and-egg: Terraform cannot create its own backend bucket in the same config without extra steps. Creating the bucket once by hand is standard for bootstrapping.

---

## Step 0.3 — Write `envs/dev/backend.tf`

This tells Terraform **where** to save state.

```hcl
terraform {
  backend "s3" {
    bucket       = "zen-pharma-terraform-state-YOUR-UNIQUE-SUFFIX"  # ← your bucket
    key          = "envs/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true   # S3 native locking (Terraform >= 1.11)
  }
}
```

| Setting | Purpose |
|---|---|
| `bucket` | S3 bucket name you created above |
| `key` | Path inside bucket — separate key per environment |
| `encrypt` | State may contain sensitive values |
| `use_lockfile` | Prevents two applies at the same time |

---

## Step 0.4 — Write `envs/dev/providers.tf`

This tells Terraform **which cloud** to use and **which providers** to download.

```hcl
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "pharma"
      Env       = "dev"
      ManagedBy = "terraform"
    }
  }
}
```

Only the **AWS provider** is required for this project. EKS, RDS, VPC, and everything else are created through AWS APIs.

---

## Step 0.5 — Write `envs/dev/variables.tf`

Secrets must **never** be hardcoded. Declare them as variables and pass values at runtime (CLI or GitHub Secrets).

```hcl
variable "db_password" {
  description = "Master password for the RDS PostgreSQL database"
  type        = string
  sensitive   = true
}

variable "jwt_secret" {
  description = "JWT signing secret for the application"
  type        = string
  sensitive   = true
}

variable "github_org" {
  description = "GitHub username or organization"
  type        = string
  default     = "YOUR-GITHUB-USERNAME"
}

variable "github_org_id" {
  description = "Numeric GitHub org/owner ID"
  type        = string
  default     = ""   # filled in Lab 5
}

variable "github_repo_ids" {
  description = "Map of repo name to numeric GitHub repo ID"
  type        = map(string)
  default     = {}   # filled in Lab 5
}
```

---

## Step 0.6 — Write `envs/dev/main.tf` (starter)

Start with shared values used by every module:

```hcl
locals {
  project = "pharma"
  env     = "dev"
  region  = "us-east-1"
}

data "aws_caller_identity" "current" {}
```

Module calls are added in Labs 1–6.

---

## Step 0.7 — Write `envs/dev/output.tf` (starter)

Empty for now; each lab adds outputs:

```hcl
# Outputs added as modules are wired in Labs 1–6
```

---

## Step 0.8 — Verify

```bash
cd envs/dev
aws configure   # if not already done
terraform init
terraform validate
```

Expected:

```
Terraform has been successfully initialized!
Success! The configuration is valid.
```

---

## Checkpoint

| File | Status |
|---|---|
| `envs/dev/backend.tf` | ✅ S3 backend configured |
| `envs/dev/providers.tf` | ✅ AWS provider configured |
| `envs/dev/variables.tf` | ✅ Sensitive inputs declared |
| `envs/dev/main.tf` | ✅ Locals only (modules come next) |
| S3 bucket | ✅ Created manually |

**Next:** [Lab 1 — VPC](01-vpc.md)
