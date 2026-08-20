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

GitHub OIDC tokens include your org and repo **numeric IDs**. Fetch them before writing IAM code.

**Important:** The GitHub API uses the org **name** in repo URLs, not the numeric org ID.

```bash
# ✅ Org/owner numeric ID — use org NAME in the URL
curl -s https://api.github.com/orgs/DPP-2026 | jq .id
# Example output: 283630436

# For personal accounts (not an org):
# curl -s https://api.github.com/users/YOUR-USERNAME | jq .id

# ✅ Repo numeric IDs — use org NAME + repo NAME in the URL
curl -s https://api.github.com/repos/DPP-2026/zen-pharma-frontend | jq .id
# Example output: 1235505603

curl -s https://api.github.com/repos/DPP-2026/zen-pharma-backend | jq .id
# Example output: 1235515471

curl -s https://api.github.com/repos/DPP-2026/zen-pharma-backend-lab1 | jq .id
# Example output: 1260221715
```

```bash
# ❌ Wrong — numeric org ID does NOT work in the repo URL
curl -s https://api.github.com/repos/283630436/zen-pharma-frontend | jq .id
# Returns: null
```

Update `envs/dev/variables.tf` defaults with your values (DPP-2026 example):

```hcl
variable "github_org" {
  default = "DPP-2026"
}

variable "github_org_id" {
  default = "283630436"
}

variable "github_repo_ids" {
  default = {
    "zen-pharma-frontend"     = "1235505603"
    "zen-pharma-backend"      = "1235515471"
    "zen-pharma-backend-lab1" = "1260221715"
  }
}
```

If you fork repos under your own org/username, re-run the curl commands with **your** org name and update all three values.

---

## Step 5.2 — Create the module folder

```bash
mkdir -p modules/iam
```

---

## Step 5.3 — Write `modules/iam/variables.tf`

```hcl
variable "project" {
  description = "Project name"
  type        = string
}

variable "env" {
  description = "Environment name (dev, qa, prod)"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the EKS OIDC provider"
  type        = string
}

variable "aws_account_id" {
  description = "AWS Account ID"
  type        = string
}

variable "github_org" {
  description = "GitHub organization or username that owns frontend and backend"
  type        = string
}

variable "github_org_id" {
  description = "Numeric GitHub organization/owner ID. Fetch via: curl https://api.github.com/orgs/<github_org>"
  type        = string
}

variable "github_repo_ids" {
  description = "Map of GitHub repo name to its numeric GitHub repository ID. Fetch via: curl https://api.github.com/repos/<github_org>/<repo>"
  type        = map(string)
}
```

**Why each input:**

| Variable | Source | Why |
|---|---|---|
| `oidc_provider_arn`, `oidc_provider_url` | `module.eks` outputs | IRSA trust policies must reference the EKS OIDC provider |
| `aws_account_id` | `data.aws_caller_identity` | Scopes Secrets Manager and ECR policy ARNs to your account |
| `github_org`, `github_org_id`, `github_repo_ids` | `envs/dev/variables.tf` | GitHub Actions OIDC trust policy matches token `sub` claims |

---

## Step 5.4 — Write `modules/iam/main.tf`

This file creates three **IRSA roles** (pod identity via EKS OIDC): ESO, ArgoCD, and AWS Load Balancer Controller.

```hcl
# ─── External Secrets Operator (ESO) IRSA Role ─────────────────────────────

data "aws_iam_policy_document" "eso_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    principals {
      identifiers = [var.oidc_provider_arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "eso_role" {
  name               = "${var.project}-${var.env}-eso-role"
  assume_role_policy = data.aws_iam_policy_document.eso_assume_role.json

  tags = {
    Name    = "${var.project}-${var.env}-eso-role"
    Env     = var.env
    Project = var.project
  }
}

resource "aws_iam_policy" "eso_secrets_policy" {
  name        = "${var.project}-${var.env}-eso-secrets-policy"
  description = "Allow External Secrets Operator to read pharma secrets from AWS Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = "arn:aws:secretsmanager:*:${var.aws_account_id}:secret:/pharma/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eso_secrets_attachment" {
  role       = aws_iam_role.eso_role.name
  policy_arn = aws_iam_policy.eso_secrets_policy.arn
}

# ─── ArgoCD IRSA Role ──────────────────────────────────────────────────────

data "aws_iam_policy_document" "argocd_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:argocd:argocd-application-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    principals {
      identifiers = [var.oidc_provider_arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "argocd_role" {
  name               = "${var.project}-${var.env}-argocd-role"
  assume_role_policy = data.aws_iam_policy_document.argocd_assume_role.json

  tags = {
    Name    = "${var.project}-${var.env}-argocd-role"
    Env     = var.env
    Project = var.project
  }
}

# ─── AWS Load Balancer Controller IRSA Role ─────────────────────────────────

data "aws_iam_policy_document" "alb_controller_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    principals {
      identifiers = [var.oidc_provider_arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "alb_controller_role" {
  name               = "${var.project}-${var.env}-alb-controller-role"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_assume_role.json

  tags = {
    Name    = "${var.project}-${var.env}-alb-controller-role"
    Env     = var.env
    Project = var.project
  }
}

resource "aws_iam_policy" "alb_controller_policy" {
  name        = "${var.project}-${var.env}-alb-controller-policy"
  description = "IAM policy for AWS Load Balancer Controller"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
          "ec2:GetCoipPoolUsage",
          "ec2:DescribeCoipPools",
          "ec2:GetSecurityGroupsForVpc",
          "ec2:DescribeIpamPools",
          "ec2:DescribeRouteTables",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeListenerCertificates",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeTrustStores",
          "elasticloadbalancing:DescribeListenerAttributes",
          "elasticloadbalancing:DescribeCapacityReservation"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:DescribeUserPoolClient",
          "acm:ListCertificates",
          "acm:DescribeCertificate",
          "iam:ListServerCertificates",
          "iam:GetServerCertificate",
          "waf-regional:GetWebACL",
          "waf-regional:GetWebACLForResource",
          "waf-regional:AssociateWebACL",
          "waf-regional:DisassociateWebACL",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
          "shield:GetSubscriptionState",
          "shield:DescribeProtection",
          "shield:CreateProtection",
          "shield:DeleteProtection"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:CreateSecurityGroup",
          "ec2:CreateTags",
          "ec2:DeleteTags",
          "ec2:DeleteSecurityGroup",
          "ec2:ModifyNetworkInterfaceAttribute"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:DeleteRule",
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags",
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:ModifyListenerAttributes",
          "elasticloadbalancing:ModifyCapacityReservation",
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets",
          "elasticloadbalancing:SetWebAcl",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:AddListenerCertificates",
          "elasticloadbalancing:RemoveListenerCertificates",
          "elasticloadbalancing:ModifyRule"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "alb_controller_policy_attachment" {
  role       = aws_iam_role.alb_controller_role.name
  policy_arn = aws_iam_policy.alb_controller_policy.arn
}
```

**Teaching point — IRSA trust policy:** Each role trusts a specific Kubernetes service account (`:sub` condition) via the EKS OIDC provider (`var.oidc_provider_arn`). Only that pod can assume that role.

---

## Step 5.5 — Write `modules/iam/github-actions-oidc.tf`

```hcl
resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = {
    Name    = "github-actions-oidc-provider"
    Project = var.project
  }
}

locals {
  github_oidc_subs = flatten([
    for repo_name, repo_id in var.github_repo_ids : flatten([
      for branch in ["main", "develop"] : [
        "repo:${var.github_org}@${var.github_org_id}/${repo_name}@${repo_id}:ref:refs/heads/${branch}",
        "repo:${var.github_org}/${repo_name}:ref:refs/heads/${branch}",
      ]
    ])
  ])
}

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.github_oidc_subs
    }
  }
}

resource "aws_iam_role" "github_actions_ci" {
  name                 = "${var.project}-${var.env}-github-actions-role"
  assume_role_policy   = data.aws_iam_policy_document.github_actions_assume_role.json
  max_session_duration = 3600

  tags = {
    Name    = "${var.project}-${var.env}-github-actions-role"
    Env     = var.env
    Project = var.project
  }
}

resource "aws_iam_policy" "github_actions_ci_policy" {
  name        = "${var.project}-${var.env}-github-actions-policy"
  description = "Allow GitHub Actions CI to push images to ECR and read EKS cluster info"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:DescribeImages",
        ]
        Resource = "arn:aws:ecr:*:${var.aws_account_id}:repository/*"
      },
      {
        Sid    = "EKSRead"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_ci_policy_attachment" {
  role       = aws_iam_role.github_actions_ci.name
  policy_arn = aws_iam_policy.github_actions_ci_policy.arn
}
```

Both immutable-ID and legacy `org/repo` sub claim formats are included in `local.github_oidc_subs` so the trust policy works before and after GitHub's OIDC format change.

---

## Step 5.6 — Write `modules/iam/outputs.tf`

```hcl
output "eso_role_arn" {
  description = "ARN of the External Secrets Operator IAM role"
  value       = aws_iam_role.eso_role.arn
}

output "argocd_role_arn" {
  description = "ARN of the ArgoCD IAM role"
  value       = aws_iam_role.argocd_role.arn
}

output "alb_controller_role_arn" {
  description = "ARN of the AWS Load Balancer Controller IAM role"
  value       = aws_iam_role.alb_controller_role.arn
}
```

**Why these outputs?** Bootstrap scripts (External Secrets, ArgoCD, ALB Controller) need the role ARNs to annotate Kubernetes service accounts. The GitHub Actions role ARN is retrieved separately after apply via `terraform output` or the AWS console.

---

## Step 5.7 — Call the module from `envs/dev/main.tf`

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

## Step 5.8 — Verify

```bash
cd envs/dev
terraform init
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

- [ ] `modules/iam/variables.tf`, `main.tf`, `github-actions-oidc.tf`, `outputs.tf` created
- [ ] GitHub org/repo IDs fetched and set in `envs/dev/variables.tf`
- [ ] Root passes EKS OIDC outputs into IAM module
- [ ] `terraform init` and `terraform plan` show IAM resources

**Next:** [Lab 6 — Secrets Manager](06-secrets-manager.md)
