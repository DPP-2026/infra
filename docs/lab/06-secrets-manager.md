# Lab 6 — Secrets Manager

**Goal:** Create `modules/secrets-manager/` and call it from `envs/dev/main.tf`, wired to RDS output.

**Depends on:** [Lab 3 — RDS](03-rds.md)

**Reference in repo:** [`modules/secrets-manager/`](../../modules/secrets-manager/)

---

## What You Are Building

| Secret path | Contents |
|---|---|
| `/pharma/dev/db-credentials` | `username`, `password`, `host` (JSON) |
| `/pharma/dev/jwt-secret` | `secret` (JSON) |

Secrets are **never** stored in Git or Kubernetes YAML. ESO syncs them at runtime using the IAM role from Lab 5.

---

## Step 6.1 — Create the module folder

```bash
mkdir -p modules/secrets-manager
```

---

## Step 6.2 — Write `modules/secrets-manager/variables.tf`

```hcl
variable "project" {
  description = "Project name"
  type        = string
}

variable "env" {
  description = "Environment name (dev, qa, prod)"
  type        = string
}

variable "db_username" {
  description = "Database username to store in Secrets Manager"
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "Database password to store in Secrets Manager"
  type        = string
  sensitive   = true
}

variable "db_host" {
  description = "RDS endpoint hostname to store alongside credentials"
  type        = string
}

variable "jwt_secret" {
  description = "JWT signing secret to store in Secrets Manager"
  type        = string
  sensitive   = true
}
```

---

## Step 6.3 — Write `modules/secrets-manager/main.tf`

```hcl
resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "/pharma/${var.env}/db-credentials"
  description             = "Database credentials for the pharma ${var.env} environment"
  recovery_window_in_days = 0

  tags = {
    Name    = "/pharma/${var.env}/db-credentials"
    Env     = var.env
    Project = var.project
  }
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
    host     = var.db_host
  })
}

resource "aws_secretsmanager_secret" "jwt_secret" {
  name                    = "/pharma/${var.env}/jwt-secret"
  description             = "JWT signing secret for the pharma ${var.env} environment"
  recovery_window_in_days = 0

  tags = {
    Name    = "/pharma/${var.env}/jwt-secret"
    Env     = var.env
    Project = var.project
  }
}

resource "aws_secretsmanager_secret_version" "jwt_secret" {
  secret_id = aws_secretsmanager_secret.jwt_secret.id
  secret_string = jsonencode({
    secret = var.jwt_secret
  })
}
```

---

## Step 6.4 — Write `modules/secrets-manager/outputs.tf`

```hcl
output "db_secret_arn" {
  description = "ARN of the database credentials secret"
  value       = aws_secretsmanager_secret.db_credentials.arn
}

output "jwt_secret_arn" {
  description = "ARN of the JWT signing secret"
  value       = aws_secretsmanager_secret.jwt_secret.arn
}
```

---

## Step 6.5 — Call the module from `envs/dev/main.tf`

```hcl
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

**Wiring:**

```hcl
db_host     = module.rds.db_instance_address   # RDS output → secret value
db_password = var.db_password                  # from -var or GitHub Secret
jwt_secret  = var.jwt_secret                   # same
```

---

## Step 6.6 — Final `envs/dev/main.tf` check

When Labs 1–6 are complete, your `main.tf` should call all six modules:

```hcl
locals {
  project = "pharma"
  env     = "dev"
  region  = "us-east-1"
}

data "aws_caller_identity" "current" {}

module "vpc"             { ... }
module "eks"             { ... }
module "rds"             { ... }
module "ecr"             { ... }
module "iam"             { ... }
module "secrets_manager" { ... }
```

Compare with the finished file: [`envs/dev/main.tf`](../../envs/dev/main.tf).

---

## Step 6.7 — Full local apply test

```bash
cd envs/dev
terraform init
terraform plan \
  -var="db_password=ChangeMe123!" \
  -var="jwt_secret=$(openssl rand -hex 32)"

terraform apply \
  -var='db_password=ChangeMe123!' \
  -var='jwt_secret=$(openssl rand -hex 32)'
```

First full apply: **~20–25 minutes** (EKS + RDS dominate).

---

## Teaching Points

| Question | Answer |
|---|---|
| Why Secrets Manager instead of ConfigMap? | Secrets not visible in Git or `kubectl get` output |
| Why `recovery_window_in_days = 0`? | Dev — instant delete on destroy; use 7+ days in prod |
| Why store `host` in the secret? | App gets a single JSON blob with everything it needs |
| Why depends on RDS? | `db_host` comes from RDS output — must exist first |

---

## Checkpoint

- [ ] All six modules wired in `envs/dev/main.tf`
- [ ] Secrets passed via `-var`, never in code
- [ ] Full `terraform apply` succeeds locally (optional but recommended before CI)
- [ ] AWS Console → Secrets Manager shows `/pharma/dev/*` secrets

**Next:** [Lab 7 — GitHub Actions](07-github-actions.md)
