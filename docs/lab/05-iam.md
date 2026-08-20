# Lab 5 — IAM Roles (IRSA + GitHub Actions OIDC)

**Goal:** Create `modules/iam/` and call it from `envs/dev/main.tf`, wired to EKS outputs.

**Depends on:** [Lab 2 — EKS](02-eks.md)

**Reference in repo:** [`modules/iam/`](../../modules/iam/)

---

## What You Are Building

| Role | Purpose | Trust |
|---|---|---|
| `pharma-dev-eso-role` | External Secrets Operator reads Secrets Manager | EKS OIDC → K8s service account |
| `pharma-dev-argocd-role` | ArgoCD deploys applications | EKS OIDC → K8s service account |
| `pharma-dev-alb-controller-role` | AWS Load Balancer Controller creates ALBs | EKS OIDC → K8s service account |
| `pharma-dev-github-actions-role` | CI pushes images to ECR | GitHub OIDC → workflow token |

---

## Step 5.1 — Fetch GitHub numeric IDs (required for OIDC)

GitHub OIDC tokens include your org and repo **numeric IDs**. Fetch them before writing IAM code:

```bash
# Org/owner ID
curl -s https://api.github.com/orgs/YOUR-GITHUB-ORG | jq .id
# For personal accounts: curl -s https://api.github.com/users/YOUR-USERNAME | jq .id

# Repo IDs
curl -s https://api.github.com/repos/YOUR-GITHUB-ORG/zen-pharma-frontend | jq .id
curl -s https://api.github.com/repos/YOUR-GITHUB-ORG/zen-pharma-backend | jq .id
curl -s https://api.github.com/repos/YOUR-GITHUB-ORG/zen-pharma-backend-lab1 | jq .id
```

Update `envs/dev/variables.tf` defaults with your values:

```hcl
variable "github_org_id" {
  default = "YOUR_ORG_ID"
}

variable "github_repo_ids" {
  default = {
    "zen-pharma-frontend"     = "YOUR_FRONTEND_REPO_ID"
    "zen-pharma-backend"      = "YOUR_BACKEND_REPO_ID"
    "zen-pharma-backend-lab1" = "YOUR_BACKEND_LAB1_REPO_ID"
  }
}
```

---

## Step 5.2 — Create the module folder

```bash
mkdir -p modules/iam
```

Create four files:

| File | Contents |
|---|---|
| `variables.tf` | `project`, `env`, `oidc_provider_arn`, `oidc_provider_url`, `aws_account_id`, `github_org`, `github_org_id`, `github_repo_ids` |
| `main.tf` | ESO, ArgoCD, ALB Controller IRSA roles |
| `github-actions-oidc.tf` | GitHub OIDC provider + CI role |
| `outputs.tf` | Role ARNs for ESO, ArgoCD, ALB Controller |

**Key inputs and why:**

```hcl
variable "oidc_provider_arn" {
  # From module.eks — EKS creates the OIDC provider for IRSA
}
variable "oidc_provider_url" {
  # Used in trust policy condition: which K8s service account can assume the role
}
variable "aws_account_id" {
  # Scopes IAM policies to your account ARNs
}
```

See full file contents in [`modules/iam/`](../../modules/iam/).

---

## Step 5.3 — Call the module from `envs/dev/main.tf`

```hcl
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
```

**Trace the wiring:**

```
module.eks.oidc_provider_arn         ──►  module.iam (IRSA trust policies)
module.eks.cluster_oidc_issuer_url   ──►  module.iam
data.aws_caller_identity.current.account_id  ──►  module.iam (policy ARNs)
```

---

## Step 5.4 — Verify

```bash
cd envs/dev
terraform plan \
  -var="db_password=dummy" \
  -var="jwt_secret=dummy"
```

Expect IAM roles, policies, OIDC provider (~10+ resources).

---

## Teaching Points

| Question | Answer |
|---|---|
| What is IRSA? | IAM Roles for Service Accounts — pods get temporary AWS creds via K8s token |
| Why two OIDC providers? | EKS OIDC for pods; GitHub OIDC for CI pipelines — different trust sources |
| Why numeric repo IDs? | GitHub's immutable OIDC `sub` claim format uses IDs, not repo names |
| Why not put IAM in EKS module? | IAM roles are app/platform concerns; keeping separate modules is cleaner |

---

## Checkpoint

- [ ] GitHub org/repo IDs fetched and set in `variables.tf`
- [ ] `modules/iam/` created with IRSA + GitHub OIDC
- [ ] Root passes EKS OIDC outputs into IAM module
- [ ] Plan shows IAM resources

**Next:** [Lab 6 — Secrets Manager](06-secrets-manager.md)
