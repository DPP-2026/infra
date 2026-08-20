# Lab 4 — ECR Repositories

**Goal:** Create `modules/ecr/` and call it from `envs/dev/main.tf`.

**Depends on:** [Lab 0 — Foundation](00-foundation.md)

**Reference in repo:** [`modules/ecr/`](../../modules/ecr/)

---

## What You Are Building

Nine ECR repositories with:
- Vulnerability scan on push
- Lifecycle policy (keep last 10 images)

| Repository | Service |
|---|---|
| `api-gateway` | Spring Cloud Gateway |
| `auth-service` | JWT authentication |
| `drug-catalog-service` | Drug catalogue |
| `inventory-service` | Stock management |
| `manufacturing-service` | Batch tracking |
| `notification-service` | Node.js notifications |
| `pharma-ui` | React frontend |
| `supplier-service` | Vendor management |
| `qc-service` | Quality control |

ECR uses **native Terraform resources** — no community module.

---

## Step 4.1 — Create the module folder

```bash
mkdir -p modules/ecr
```

---

## Step 4.2 — Write `modules/ecr/variables.tf`

```hcl
variable "project" {
  description = "Project name"
  type        = string
}

variable "env" {
  description = "Environment name (dev, qa, prod)"
  type        = string
}

variable "repositories" {
  description = "List of ECR repository names to create"
  type        = list(string)
}
```

**Why `repositories` as a list input?** Adding a new service = add one string in root `main.tf`, not edit the module.

---

## Step 4.3 — Write `modules/ecr/main.tf`

```hcl
resource "aws_ecr_repository" "main" {
  for_each = toset(var.repositories)

  name                 = each.value
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name    = "${var.project}-${each.value}"
    Env     = var.env
    Project = var.project
  }
}

resource "aws_ecr_lifecycle_policy" "main" {
  for_each   = toset(var.repositories)
  repository = aws_ecr_repository.main[each.key].name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
```

**Teaching point — `for_each`:** One block creates many repositories.

---

## Step 4.4 — Write `modules/ecr/outputs.tf`

```hcl
output "repository_urls" {
  description = "Map of repository name to repository URL"
  value       = { for name, repo in aws_ecr_repository.main : name => repo.repository_url }
}
```

---

## Step 4.5 — Call the module from `envs/dev/main.tf`

```hcl
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
```

---

## Step 4.6 — Verify

```bash
cd envs/dev
terraform plan \
  -var="db_password=dummy" \
  -var="jwt_secret=dummy"
```

Expect 18 resources (9 repos + 9 lifecycle policies).

Optional apply — check AWS Console → ECR → Repositories.

---

## Teaching Points

| Question | Answer |
|---|---|
| Why `for_each` instead of nine separate resources? | DRY — one block, many repos |
| Why lifecycle policy? | Prevents unbounded storage cost from old images |
| Why `scan_on_push`? | Catches CVEs when CI pushes images |
| Does ECR need VPC? | No — ECR is a regional AWS API, not network-bound |

---

## Checkpoint

- [ ] `modules/ecr/` created
- [ ] Root passes `repositories` list
- [ ] Plan shows 18 ECR resources

**Next:** [Lab 5 — IAM](05-iam.md)
