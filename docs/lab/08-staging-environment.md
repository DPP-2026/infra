# Lab 8 — Add a Staging (`stg`) Environment

**Goal:** Provision a second environment using the **same modules** with different config, state, and secrets.

**Depends on:** Labs 0–7 complete (`envs/dev/` working)

**Key idea:** Modules are written once in `modules/`. Each environment is a separate folder under `envs/` that calls those modules with different values.

---

## What Changes vs What Stays the Same

| Item | Dev | Staging (`stg`) |
|---|---|---|
| Module code (`modules/*`) | — | **No changes** — reuse as-is |
| Environment folder | `envs/dev/` | **New** `envs/stg/` |
| State file (S3 key) | `envs/dev/terraform.tfstate` | `envs/stg/terraform.tfstate` |
| `local.env` | `"dev"` | `"stg"` |
| VPC CIDR | `10.0.0.0/16` | `10.1.0.0/16` (must not overlap dev) |
| EKS sizing | t3.small, 4 nodes | t3.medium, 2 nodes (example) |
| RDS sizing | db.t3.micro | db.t3.small (example) |
| Secrets path | `/pharma/dev/*` | `/pharma/stg/*` (automatic via `var.env`) |
| GitHub Secrets | `DEV_DB_PASSWORD`, `DEV_JWT_SECRET` | `STG_DB_PASSWORD`, `STG_JWT_SECRET` |
| GitHub Environment | `dev` | `stg` |

---

## Step 8.1 — Create `envs/stg/` by copying dev

```bash
cp -r envs/dev envs/stg
```

Remove Terraform cache from the copy (do not commit these):

```bash
rm -rf envs/stg/.terraform envs/stg/.terraform.lock.hcl envs/stg/tfplan
```

---

## Step 8.2 — Update `envs/stg/backend.tf`

Use the **same S3 bucket** but a **different state key** — this isolates staging from dev:

```hcl
terraform {
  backend "s3" {
    bucket       = "zen-pharma-terraform-state-YOUR-UNIQUE-SUFFIX"
    key          = "envs/stg/terraform.tfstate"   # ← changed from envs/dev/
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

| Setting | Why |
|---|---|
| Same bucket | One bucket, many state files — standard pattern |
| Different `key` | Dev and stg never share or overwrite each other's state |

---

## Step 8.3 — Update `envs/stg/providers.tf`

Change the default tag to match staging:

```hcl
provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "pharma"
      Env       = "stg"          # ← changed from dev
      ManagedBy = "terraform"
    }
  }
}
```

---

## Step 8.4 — Update `envs/stg/main.tf`

Change `locals` and environment-specific sizing. **Module `source` paths stay the same** (`../../modules/...`).

```hcl
locals {
  project = "pharma"
  env     = "stg"               # ← changed
  region  = "us-east-1"
}

data "aws_caller_identity" "current" {}

module "vpc" {
  source = "../../modules/vpc"

  project               = local.project
  env                   = local.env
  region                = local.region
  vpc_cidr              = "10.1.0.0/16"                    # ← different CIDR
  public_subnet_cidrs   = ["10.1.1.0/24", "10.1.2.0/24"]
  private_subnet_cidrs  = ["10.1.3.0/24", "10.1.4.0/24"]
  database_subnet_cidrs = ["10.1.5.0/24", "10.1.6.0/24"]
}

module "eks" {
  source = "../../modules/eks"

  project            = local.project
  env                = local.env
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnets
  kubernetes_version = "1.35"
  instance_types     = ["t3.medium"]                       # ← staging sizing
  min_size           = 1
  max_size           = 4
  desired_size       = 2
}

module "rds" {
  source = "../../modules/rds"

  project                    = local.project
  env                        = local.env
  username                   = "pharmaadmin"
  password                   = var.db_password
  vpc_id                     = module.vpc.vpc_id
  db_subnet_group_name       = module.vpc.database_subnet_group_name
  eks_node_security_group_id = module.eks.node_security_group_id
  instance_class             = "db.t3.small"               # ← staging sizing
}

module "ecr" {
  source = "../../modules/ecr"

  project = local.project
  env     = local.env
  repositories = [
    "api-gateway",
    "auth-service",
    "drug-catalog-service",
    "inventory-service",
    "manufacturing-service",
    "notification-service",
    "pharma-ui",
    "supplier-service",
    "qc-service",
  ]
}

module "iam" {
  source = "../../modules/iam"

  project           = local.project
  env               = local.env
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.cluster_oidc_issuer_url
  aws_account_id    = data.aws_caller_identity.current.account_id
  github_org        = var.github_org
  github_org_id     = var.github_org_id
  github_repo_ids   = var.github_repo_ids
}

module "secrets_manager" {
  source = "../../modules/secrets-manager"

  project     = local.project
  env         = local.env
  db_username = "pharmaadmin"
  db_password = var.db_password
  db_host     = module.rds.db_instance_address
  jwt_secret  = var.jwt_secret
}
```

### ECR note — same AWS account

ECR repository names in this project are **not** prefixed with the environment (e.g. `api-gateway`, not `stg-api-gateway`). If dev already created them, staging `terraform apply` will fail with "repository already exists".

**Options:**

| Approach | When to use |
|---|---|
| **Remove `module "ecr"` from `envs/stg/main.tf`** | Staging uses the same image repos as dev (most common) |
| **Import existing repos** into stg state | Advanced — only if you need stg state to track them |
| **Rename repos per env** | Requires changing the ECR module — not needed for this lab |

For learning, **remove the ECR module block from stg** if dev already provisioned the repos.

---

## Step 8.5 — Keep `envs/stg/variables.tf`

Same structure as dev — variable names stay `db_password` and `jwt_secret`. Values come from different GitHub Secrets at apply time.

Update `github_org` / `github_org_id` / `github_repo_ids` if staging uses different repos (usually same as dev).

---

## Step 8.6 — Initialize and plan locally

```bash
cd envs/stg
terraform init
terraform plan \
  -var="db_password=StgChangeMe123!" \
  -var="jwt_secret=$(openssl rand -hex 32)"
```

You should see a **full new stack** — `pharma-stg-vpc`, `pharma-stg-cluster`, `pharma-stg-postgres`, etc. Nothing should reference dev resources.

---

## Step 8.7 — GitHub Secrets for staging

Go to **Settings → Secrets and variables → Actions → Secrets**. Add:

| Secret | Value |
|---|---|
| `STG_DB_PASSWORD` | Strong password (different from dev) |
| `STG_JWT_SECRET` | Random string (`openssl rand -hex 32`) |

AWS credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) are usually **shared** across environments in the same account.

---

## Step 8.8 — GitHub Environment for staging

Go to **Settings → Environments → New environment**:

- Name: `stg`
- Enable **Required reviewers**
- Save

This gives staging its own approval gate, separate from `dev`.

---

## Step 8.9 — Extend the GitHub Actions workflow

The current workflow only targets `envs/dev/`. Add staging by either duplicating jobs or using a matrix. Minimal approach — add path triggers and a second job set:

**1. Update `on.push.paths` and `on.pull_request.paths`:**

```yaml
paths:
  - 'envs/dev/**'
  - 'envs/stg/**'      # ← add
  - 'modules/**'
```

**2. Duplicate the plan/apply/destroy jobs for stg** (or parameterize with a matrix). Key differences in the stg jobs:

```yaml
defaults:
  run:
    working-directory: envs/stg    # ← changed

environment: stg                   # ← changed

# In plan step:
terraform plan \
  -var="db_password=${{ secrets.STG_DB_PASSWORD }}" \
  -var="jwt_secret=${{ secrets.STG_JWT_SECRET }}" \
  ...
```

**3. Use separate concurrency groups per environment** to avoid state lock conflicts:

```yaml
concurrency:
  group: terraform-stg-${{ github.ref }}
```

---

## Step 8.10 — Apply staging via pipeline

```bash
git checkout -b feat/stg-environment
git add envs/stg/
git commit -m "feat: add staging environment"
git push -u origin feat/stg-environment
```

Open a PR → plan runs for both `envs/dev` and `envs/stg` (if workflow updated). Merge → approve the `stg` environment deployment.

---

## Dev vs Stg — side-by-side checklist

| Check | Dev | Stg |
|---|---|---|
| Folder exists | `envs/dev/` | `envs/stg/` |
| State key | `envs/dev/terraform.tfstate` | `envs/stg/terraform.tfstate` |
| `local.env` | `"dev"` | `"stg"` |
| VPC CIDR unique | ✅ | ✅ (different range) |
| Modules unchanged | ✅ | ✅ |
| Secrets in GitHub | `DEV_*` | `STG_*` |
| GitHub Environment | `dev` | `stg` |
| Workflow `working-directory` | `envs/dev` | `envs/stg` |

---

## Next steps

For production with HA and stricter controls, continue to [Lab 9 — Production](09-production-environment.md).

---

## Checkpoint

- [ ] `envs/stg/` created with unique backend key and VPC CIDR
- [ ] `local.env = "stg"` in main.tf and providers.tf
- [ ] ECR module removed or handled if repos already exist from dev
- [ ] `terraform plan` in `envs/stg/` shows new resources only
- [ ] GitHub Secrets `STG_DB_PASSWORD` and `STG_JWT_SECRET` set
- [ ] GitHub Environment `stg` created with required reviewer
- [ ] Workflow updated to plan/apply `envs/stg/`

**Back to:** [Lab index](README.md)
