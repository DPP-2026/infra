# Lab 9 — Add a Production (`prod`) Environment

**Goal:** Provision a production environment with **higher availability, stronger safeguards, and stricter CI/CD controls** — using the same modules as dev/stg.

**Depends on:** [Lab 8 — Staging](08-staging-environment.md) (recommended — validate stg before prod)

**Key idea:** Production is not a different codebase. It is another folder under `envs/` with production-grade **input values** and **operational guardrails**.

---

## How Prod Differs from Dev and Stg

| Item | Dev | Stg | Prod |
|---|---|---|---|
| Purpose | Learning, fast iteration | Pre-prod validation | Live workloads |
| VPC CIDR | `10.0.0.0/16` | `10.1.0.0/16` | `10.2.0.0/16` |
| EKS nodes | t3.small × 4 | t3.medium × 2 | t3.large × 3+ (example) |
| EKS min / max | 1 / 5 | 1 / 4 | 3 / 10 |
| RDS instance | db.t3.micro | db.t3.small | db.t3.medium+ |
| RDS Multi-AZ | No | No | **Yes** |
| RDS backups | 0 days | 0 days | **7 days** |
| RDS deletion protection | No | No | **Yes** |
| Final snapshot on destroy | Skipped | Skipped | **Taken** |
| NAT Gateway | Single | Single | Consider dual NAT (HA) |
| GitHub approval | 1 reviewer | 1 reviewer | **2+ reviewers, no self-review** |
| Secrets | `DEV_*` | `STG_*` | `PROD_*` |
| ECR module | Yes (creates repos) | Remove (shared) | **Remove (shared)** |

---

## Step 9.1 — Create `envs/prod/` by copying stg or dev

```bash
cp -r envs/stg envs/prod
# or: cp -r envs/dev envs/prod
```

Remove Terraform cache:

```bash
rm -rf envs/prod/.terraform envs/prod/.terraform.lock.hcl envs/prod/tfplan
```

---

## Step 9.2 — Update `envs/prod/backend.tf`

```hcl
terraform {
  backend "s3" {
    bucket       = "zen-pharma-terraform-state-YOUR-UNIQUE-SUFFIX"
    key          = "envs/prod/terraform.tfstate"   # ← prod state key
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

Each environment **must** have its own state key. Never share state between dev, stg, and prod.

---

## Step 9.3 — Update `envs/prod/providers.tf`

```hcl
provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "pharma"
      Env       = "prod"
      ManagedBy = "terraform"
    }
  }
}
```

---

## Step 9.4 — Update `envs/prod/main.tf` with production sizing

**Module `source` paths are unchanged.** Only inputs and `locals` differ.

```hcl
locals {
  project = "pharma"
  env     = "prod"
  region  = "us-east-1"
}

data "aws_caller_identity" "current" {}

module "vpc" {
  source = "../../modules/vpc"

  project               = local.project
  env                   = local.env
  region                = local.region
  vpc_cidr              = "10.2.0.0/16"
  public_subnet_cidrs   = ["10.2.1.0/24", "10.2.2.0/24"]
  private_subnet_cidrs  = ["10.2.3.0/24", "10.2.4.0/24"]
  database_subnet_cidrs = ["10.2.5.0/24", "10.2.6.0/24"]
}

module "eks" {
  source = "../../modules/eks"

  project            = local.project
  env                = local.env
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnets
  kubernetes_version = "1.35"
  instance_types     = ["t3.large"]
  min_size           = 3
  max_size           = 10
  desired_size       = 3
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

  instance_class          = "db.t3.medium"
  allocated_storage       = 50
  multi_az                = true
  backup_retention_period = 7
  deletion_protection     = true
  skip_final_snapshot     = false
}

# ECR — omit in prod if dev already created the repos (shared across envs)
# module "ecr" { ... }

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

### Production RDS inputs — why each matters

| Input | Prod value | Why |
|---|---|---|
| `multi_az = true` | Standby replica in another AZ | Automatic failover if primary fails |
| `backup_retention_period = 7` | 7 days of automated backups | Point-in-time recovery |
| `deletion_protection = true` | Cannot delete DB from console/API accidentally | Prevents costly mistakes |
| `skip_final_snapshot = false` | Snapshot taken before destroy | Last-resort recovery on teardown |
| `allocated_storage = 50` | More headroom | Production data grows faster |

These are all **module variables** — you do not edit `modules/rds/main.tf` for prod.

---

## Step 9.5 — Update `envs/prod/output.tf`

Same outputs as dev — useful for CI and runbooks:

```hcl
output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "rds_endpoint" {
  value = module.rds.db_instance_endpoint
}
```

---

## Step 9.6 — Plan locally before any apply

**Always plan prod manually first.** Never apply prod for the first time without reviewing the full plan.

```bash
cd envs/prod
terraform init
terraform plan \
  -var="db_password=REPLACE_WITH_STRONG_PASSWORD" \
  -var="jwt_secret=$(openssl rand -hex 32)"
```

Review the plan carefully:

- [ ] Resource names contain `pharma-prod-*`
- [ ] VPC CIDR is `10.2.0.0/16` (no overlap with dev/stg)
- [ ] RDS shows `multi_az = true` and `deletion_protection = true`
- [ ] No unexpected destroys of dev/stg resources

---

## Step 9.7 — GitHub Secrets for production

Add **separate** secrets — never reuse dev or stg passwords:

| Secret | Notes |
|---|---|
| `PROD_DB_PASSWORD` | Long, random, stored in a password manager |
| `PROD_JWT_SECRET` | `openssl rand -hex 32` — different from dev/stg |

Generate:

```bash
openssl rand -base64 32    # DB password
openssl rand -hex 32       # JWT secret
```

---

## Step 9.8 — GitHub Environment for production (strict)

Go to **Settings → Environments → New environment → `prod`**

Recommended protection rules:

| Rule | Setting |
|---|---|
| Required reviewers | **2 or more** team members |
| Prevent self-review | **Enabled** — approver cannot be the person who merged |
| Deployment branches | Restrict to `main` only |
| Wait timer | Optional 5–15 min cooling-off period |

Production should be **harder to deploy than dev**.

---

## Step 9.9 — Extend the GitHub Actions workflow

Add prod to path triggers:

```yaml
paths:
  - 'envs/dev/**'
  - 'envs/stg/**'
  - 'envs/prod/**'
  - 'modules/**'
```

Add prod jobs (mirror dev/stg structure):

```yaml
  plan-prod:
    name: Terraform Plan (prod)
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: envs/prod
    steps:
      # ... checkout, setup terraform, aws credentials ...
      - name: Terraform Plan
        run: |
          terraform plan \
            -var="db_password=${{ secrets.PROD_DB_PASSWORD }}" \
            -var="jwt_secret=${{ secrets.PROD_JWT_SECRET }}" \
            -var="github_org=YOUR-GITHUB-ORG" \
            -out=tfplan \
            -no-color

  apply-prod:
    name: Terraform Apply (prod)
    needs: plan-prod
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    environment: prod          # ← strict approval gate
    defaults:
      run:
        working-directory: envs/prod
    steps:
      # ... download tfplan, terraform apply ...
```

Use a **separate concurrency group** so prod never runs in parallel with dev/stg:

```yaml
concurrency:
  group: terraform-prod-${{ github.ref }}
  cancel-in-progress: false
```

### Optional — restrict prod workflow to manual dispatch only

For maximum safety, prod apply runs only when triggered manually:

```yaml
apply-prod:
  if: github.event_name == 'workflow_dispatch' && github.event.inputs.action == 'apply'
```

PRs to `main` still run `plan-prod` — but apply requires an explicit manual trigger.

---

## Step 9.10 — Deploy production

```bash
git checkout -b feat/prod-environment
git add envs/prod/
git commit -m "feat: add production environment"
git push -u origin feat/prod-environment
```

1. Open PR → review **plan-prod** output in Actions
2. Get PR approved and merge
3. Go to Actions → approve **`prod`** environment deployment
4. Monitor apply (~25–30 min for full stack)

---

## Step 9.11 — Post-deploy verification

```bash
# EKS
aws eks update-kubeconfig --region us-east-1 --name pharma-prod-cluster
kubectl get nodes

# RDS
aws rds describe-db-instances \
  --db-instance-identifier pharma-prod-postgres \
  --query 'DBInstances[0].{Status:DBInstanceStatus,MultiAZ:MultiAZ,DeletionProtection:DeletionProtection}'

# Secrets
aws secretsmanager list-secrets \
  --query 'SecretList[?contains(Name, `/pharma/prod`)].Name'
```

Expected: Multi-AZ enabled, deletion protection on, secrets at `/pharma/prod/*`.

---

## Production destroy — extra caution

Destroying prod is irreversible for live users. The workflow should require:

1. Manual `workflow_dispatch` with `action: destroy`
2. Typing `destroy` to confirm
3. **`prod` environment approval** from 2+ reviewers
4. RDS `skip_final_snapshot = false` ensures a final snapshot is taken

```bash
# Local destroy (emergency only — prefer pipeline)
cd envs/prod
terraform destroy \
  -var="db_password=dummy" \
  -var="jwt_secret=dummy"
```

With `deletion_protection = true`, you must first set `deletion_protection = false` in Terraform and apply before destroy will succeed.

---

## Environment comparison checklist

| Check | Dev | Stg | Prod |
|---|---|---|---|
| Folder | `envs/dev/` | `envs/stg/` | `envs/prod/` |
| State key | `envs/dev/...` | `envs/stg/...` | `envs/prod/...` |
| Unique VPC CIDR | `10.0.0.0/16` | `10.1.0.0/16` | `10.2.0.0/16` |
| RDS Multi-AZ | No | No | **Yes** |
| RDS deletion protection | No | No | **Yes** |
| RDS backups | 0 days | 0 days | **7 days** |
| ECR module | Yes | No (shared) | No (shared) |
| GitHub Secrets | `DEV_*` | `STG_*` | `PROD_*` |
| GitHub Environment | `dev` | `stg` | `prod` (2+ reviewers) |
| Apply trigger | Push to main | Push to main | Push or manual only |

---

## Checkpoint

- [ ] `envs/prod/` created with unique backend key and VPC CIDR `10.2.0.0/16`
- [ ] RDS prod inputs: Multi-AZ, deletion protection, 7-day backups, final snapshot
- [ ] EKS prod sizing: min 3 nodes, larger instance type
- [ ] ECR module omitted (repos shared from dev)
- [ ] `terraform plan` reviewed manually before first apply
- [ ] GitHub Secrets `PROD_DB_PASSWORD` and `PROD_JWT_SECRET` set
- [ ] GitHub Environment `prod` with 2+ required reviewers
- [ ] Workflow includes plan/apply for `envs/prod/`
- [ ] Post-deploy verification passed

**Back to:** [Lab index](README.md)
