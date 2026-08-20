# Zen-Pharma Infrastructure Lab — Build It Yourself

This lab teaches candidates to **build the zen-pharma infrastructure from scratch** using Terraform modules:

1. Set up foundation files in `envs/dev/` (`provider.tf`, `backend.tf`, `variables.tf`, `output.tf`)
2. Create each resource directly in `modules/<resource>/` (`variables.tf`, `main.tf`, `outputs.tf`)
3. Call the module from `envs/dev/main.tf`
4. Wire module outputs into the next module's inputs
5. Set up GitHub Actions to plan and apply automatically

**Do not fork and apply blindly.** Follow each lab in order. By the end, your repo will match the production layout and the GitHub Actions pipeline will provision AWS.

---

## Prerequisites

| Tool | Version |
|---|---|
| Terraform | 1.11+ (CI uses 1.15.6) |
| AWS CLI | 2.x |
| Git | 2.x |
| AWS account | Admin or broad IAM for learning |

## Module pattern

Every resource lab follows the same structure:

```
modules/vpc/              ← write resource code here (variables.tf, main.tf, outputs.tf)
envs/dev/main.tf          ← call: module "vpc" { source = "../../modules/vpc" ... }
```

Repeat for each resource — only the module name and inputs change.

---

## Lab Order

Complete these in sequence. Each lab depends on the previous one.

| # | Lab | What you build | Time (approx.) |
|---|---|---|---|
| 0 | [Foundation & S3 Backend](00-foundation.md) | Repo layout, provider, backend, secrets variables | 30 min |
| 1 | [VPC](01-vpc.md) | VPC, subnets, NAT, database subnet group | 45 min |
| 2 | [EKS](02-eks.md) | Kubernetes cluster and node group | 45 min |
| 3 | [RDS](03-rds.md) | PostgreSQL in private subnets | 30 min |
| 4 | [ECR](04-ecr.md) | Container image repositories | 20 min |
| 5 | [IAM](05-iam.md) | IRSA roles and GitHub Actions OIDC | 45 min |
| 6 | [Secrets Manager](06-secrets-manager.md) | DB credentials and JWT secret | 20 min |
| 7 | [GitHub Actions CI/CD](07-github-actions.md) | Workflow, secrets, variables, approval gate | 45 min |
| 8 | [Staging Environment](08-staging-environment.md) | Add `envs/stg/` reusing the same modules | 30 min |
| 9 | [Production Environment](09-production-environment.md) | Add `envs/prod/` with HA and stricter controls | 45 min |

**Total:** ~4–5 hours of hands-on work (apply time for EKS/RDS adds ~20 min on first run).

---

## Per-Lab Pattern (same every time)

```
Step 1  →  mkdir modules/<resource>/
Step 2  →  Write variables.tf  (inputs)
Step 3  →  Write main.tf       (resources)
Step 4  →  Write outputs.tf    (values for other modules)
Step 5  →  Add module block to envs/dev/main.tf
Step 6  →  terraform init && terraform plan
```

---

## Target Repository Layout

When all labs are complete, your tree should look like this:

```
infra/
├── .github/
│   └── workflows/
│       └── terraform.yml
├── envs/
│   ├── dev/
│   ├── stg/                 ← Lab 8
│   └── prod/                ← Lab 9
│       ├── backend.tf
│       ├── providers.tf
│       ├── variables.tf
│       ├── main.tf          ← calls all modules
│       └── output.tf
└── modules/
    ├── vpc/
    ├── eks/
    ├── rds/
    ├── ecr/
    ├── iam/
    └── secrets-manager/
```

---

## How Modules Connect (Preview)

You will wire modules together in `envs/dev/main.tf`:

```
module.vpc
  └── vpc_id, private_subnets, database_subnet_group_name
        │
        ├──► module.eks   (vpc_id, subnet_ids)
        │         └── oidc_provider_arn, node_security_group_id
        │                   │
        │                   ├──► module.rds  (vpc_id, db_subnet_group, eks SG)
        │                   └──► module.iam  (oidc for IRSA roles)
        │
module.rds ──► db_host ──► module.secrets_manager
```

---

## Teaching Tips for Instructors

- **One lab per session** works well (Lab 0 + Lab 1 in session 1, etc.).
- After each lab, run `terraform plan` — learners should see resources for all modules added so far.
- Emphasize **why** each variable and output exists (same questions as the [Modules Guide](../terraform-modules-guide.md)).
- Lab 7 is when learners first run the full stack via GitHub Actions — do not skip the manual `terraform plan` checks in earlier labs.
- Remind learners to **destroy** dev infra when not in use (~$160/month). See Lab 7 for the destroy workflow.

---

## Quick Links

- [Main README — full deployment guide](../../README.md)
- [Terraform Modules Guide](../terraform-modules-guide.md) — deep dive on inputs/outputs
