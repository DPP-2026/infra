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
| ECR module | Creates repos (once) | **Omit** — shared repos (see notes below) |

---

## Notes — dev and stg in the same AWS account

In production, dev/stg/prod usually live in **separate AWS accounts** — no naming overlap. For learning, you may use **one account**. Most resources are env-prefixed (`pharma-dev-*` vs `pharma-stg-*`) and work fine. A few need extra care.

### Same account vs separate accounts

```
Practice (one account)              Real prod (multi-account)
──────────────────────              ─────────────────────────
pharma-dev-vpc + pharma-stg-vpc     Each account has its own VPC
Shared ECR repos                    Each account has its own repos
One GitHub OIDC provider per URL    One provider per account (natural)
Must use different VPC CIDRs        CIDR can repeat across accounts
```

---

### 1. ECR — single repos, build once, deploy many (no conflict if done right)

**Strategy:** One set of ECR repos for all environments. CI builds an image once, then promotes the **same tag** to dev → stg → prod clusters.

```
CI push  →  ecr.../api-gateway:1.2.3
                    │
     ┌──────────────┼──────────────┐
     ▼              ▼              ▼
  dev EKS        stg EKS        prod EKS
 (deploy tag)   (deploy tag)   (deploy tag)
```

Repo names are **not** env-prefixed (`api-gateway`, not `stg-api-gateway`). That is intentional for promotion.

| | Suggestion |
|---|---|
| **Hard conflict** | Running `module "ecr"` in stg after dev → `RepositoryAlreadyExistsException` |
| **Fix** | **Remove `module "ecr"` from `envs/stg/main.tf`**. Keep ECR only in dev (or a one-time bootstrap). |
| **Promotion** | Tag images by version/SHA (`:1.2.3`, `:abc123`). Deploy that tag to each cluster via ArgoCD/Helm — not separate repos per env. |

---

### 2. VPC CIDR — variabilised, set per environment in `main.tf`

CIDR ranges are **module inputs**, not hardcoded in `modules/vpc/`. Each environment passes its own values in `envs/<env>/main.tf`:

```hcl
# modules/vpc/variables.tf exposes:
#   vpc_cidr, public_subnet_cidrs, private_subnet_cidrs, database_subnet_cidrs

# envs/dev/main.tf
vpc_cidr = "10.0.0.0/16"
public_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]
# ...

# envs/stg/main.tf — different range, same module
vpc_cidr = "10.1.0.0/16"
public_subnet_cidrs = ["10.1.1.0/24", "10.1.2.0/24"]
# ...
```

| | Suggestion |
|---|---|
| **Hard conflict** | Same CIDR in dev and stg (`10.0.0.0/16` twice) → overlapping networks, routing problems |
| **Fix** | Use a **unique `/16` per environment** in the same account: dev `10.0.0.0/16`, stg `10.1.0.0/16`, prod `10.2.0.0/16`. No module code changes — only `envs/stg/main.tf`. |

`vpc_cidr` has a default of `10.0.0.0/16` in the module — **always override explicitly** in stg/prod so you do not accidentally reuse dev's range.

---

### 3. GitHub Actions OIDC provider — hard conflict

The IAM module creates an account-level resource:

```hcl
resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}
```

AWS allows **only one OIDC provider per URL per account**. Dev creates it; stg tries again → **already exists**.

| | Suggestion |
|---|---|
| **Hard conflict** | Second `terraform apply` in stg fails on `aws_iam_openid_connect_provider.github_actions` |
| **Fix (practice)** | After dev exists, **import** the provider into stg state (one-time): |

```bash
cd envs/stg
# Get your account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

terraform import \
  'module.iam.aws_iam_openid_connect_provider.github_actions' \
  "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
```

Then re-run `terraform plan` — stg should manage the **roles** (`pharma-stg-github-actions-role`, etc.) but treat the OIDC provider as already existing.

| **Fix (real prod)** | Separate AWS accounts — each account gets its own provider naturally. |
| **Fix (long term)** | Move the GitHub OIDC provider to a one-time **bootstrap** stack applied once per account, not per environment. |

The **IAM roles** (`pharma-dev-*` vs `pharma-stg-*`) do not conflict — only the shared OIDC provider does.

---

### 4. Other hard conflicts — none for most resources

These are **safe** in the same account because names include `var.env`:

| Resource | Dev | Stg | Conflict? |
|---|---|---|---|
| VPC | `pharma-dev-vpc` | `pharma-stg-vpc` | No |
| EKS cluster | `pharma-dev-cluster` | `pharma-stg-cluster` | No |
| EKS OIDC (IRSA) | Per-cluster URL/ARN | Per-cluster URL/ARN | No |
| RDS | `pharma-dev-postgres` | `pharma-stg-postgres` | No |
| Secrets Manager | `/pharma/dev/*` | `/pharma/stg/*` | No |
| IAM IRSA roles | `pharma-dev-eso-role` | `pharma-stg-eso-role` | No |
| Terraform state | `envs/dev/terraform.tfstate` | `envs/stg/terraform.tfstate` | No (different S3 keys) |

---

### 5. Soft conflicts — not apply errors, but watch out

| Topic | What happens | Suggestion |
|---|---|---|
| **Cost** | Two VPCs → two NAT gateways, two EKS clusters, two RDS | Expect ~2× dev spend; destroy stg when not in use |
| **Service quotas** | More VPCs/EKS clusters per region | Usually fine for 2 envs; check AWS quotas if scaling up |
| **Wrong directory** | `terraform apply` from `envs/dev` when you meant stg | Always `cd envs/stg` first; use separate GitHub workflow jobs |
| **Shared secrets confusion** | App points at dev DB instead of stg | Use `/pharma/stg/*` secrets and stg-only `STG_*` GitHub Secrets |
| **Parallel applies** | Two workflows lock the same state file | Separate concurrency groups per env (`terraform-stg-*`) |

---

### Quick checklist before first stg apply

- [ ] Unique VPC CIDR in `envs/stg/main.tf` (not `10.0.0.0/16`)
- [ ] **`module "ecr"` removed** from stg — shared repos, build once / deploy many
- [ ] Separate state key `envs/stg/terraform.tfstate`
- [ ] Plan to **import** GitHub OIDC provider if dev IAM module already ran
- [ ] Separate `STG_DB_PASSWORD` / `STG_JWT_SECRET` (never reuse dev passwords)

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

# ECR — omit in stg. Single repos shared across envs (build once, deploy many).
# Dev already created api-gateway, auth-service, etc.

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

See **[Notes — dev and stg in the same AWS account](#notes--dev-and-stg-in-the-same-aws-account)** for ECR promotion, CIDR inputs, GitHub OIDC import, and other conflicts.

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
| VPC CIDR unique | ✅ `10.0.0.0/16` in `main.tf` | ✅ `10.1.0.0/16` in `main.tf` |
| ECR module | Creates repos | **Omitted** (shared) |
| GitHub OIDC provider | Creates (once) | Import into stg state |
| Modules unchanged | ✅ | ✅ |
| Secrets in GitHub | `DEV_*` | `STG_*` |
| GitHub Environment | `dev` | `stg` |
| Workflow `working-directory` | `envs/dev` | `envs/stg` |

---

## Next steps

For production with HA and stricter controls, continue to [Lab 9 — Production](09-production-environment.md).

---

## Checkpoint

- [ ] `envs/stg/` created with unique backend key and VPC CIDR in `main.tf`
- [ ] `local.env = "stg"` in main.tf and providers.tf
- [ ] **`module "ecr"` removed** — shared repos, build once / deploy many
- [ ] GitHub OIDC provider imported into stg state if dev IAM already applied
- [ ] `terraform plan` in `envs/stg/` shows new resources only
- [ ] GitHub Secrets `STG_DB_PASSWORD` and `STG_JWT_SECRET` set
- [ ] GitHub Environment `stg` created with required reviewer
- [ ] Workflow updated to plan/apply `envs/stg/`

**Back to:** [Lab index](README.md)
