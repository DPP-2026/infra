# Lab 2 — EKS Cluster

**Goal:** Create `modules/eks/` and call it from `envs/dev/main.tf`, wired to VPC outputs.

**Depends on:** [Lab 1 — VPC](01-vpc.md)

**Reference in repo:** [`modules/eks/`](../../modules/eks/)

---

## What You Are Building

| Setting | Dev value |
|---|---|
| Cluster name | `pharma-dev-cluster` |
| Kubernetes version | `1.35` |
| Node instance type | `t3.small` |
| Desired nodes | `4` (min 1, max 5) |
| Subnets | VPC **private** subnets (not public) |

---

## Step 2.1 — Create the module folder

```bash
mkdir -p modules/eks
```

---

## Step 2.2 — Write `modules/eks/variables.tf`

```hcl
variable "project" {
  description = "Project name"
  type        = string
}

variable "env" {
  description = "Environment name (dev, qa, prod)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the EKS cluster"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for EKS nodes"
  type        = list(string)
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.35"
}

variable "instance_types" {
  description = "Instance types for the node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 3
}
```

**Why `vpc_id` and `subnet_ids` have no default?** The caller must pass them — forces correct dependency on VPC.

---

## Step 2.3 — Write `modules/eks/main.tf`

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "${var.project}-${var.env}-cluster"
  kubernetes_version = var.kubernetes_version

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  endpoint_private_access = true
  endpoint_public_access  = true

  enable_irsa                              = true
  enable_cluster_creator_admin_permissions = true

  addons = {
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }
    kube-proxy             = { most_recent = true }
    coredns                = { most_recent = true }
    eks-pod-identity-agent = { most_recent = true }
  }

  eks_managed_node_groups = {
    main = {
      instance_types = var.instance_types
      min_size       = var.min_size
      max_size       = var.max_size
      desired_size   = var.desired_size
    }
  }

  tags = {
    Project = var.project
    Env     = var.env
  }
}
```

---

## Step 2.4 — Write `modules/eks/outputs.tf`

```hcl
output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint for the EKS cluster API server"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data for the cluster"
  value       = module.eks.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC Provider for IRSA"
  value       = module.eks.oidc_provider_arn
}

output "cluster_oidc_issuer_url" {
  description = "URL of the OIDC Provider for IRSA"
  value       = module.eks.cluster_oidc_issuer_url
}

output "node_security_group_id" {
  description = "Security group ID of the EKS node group"
  value       = module.eks.node_security_group_id
}

output "cluster_security_group_id" {
  description = "Security group ID of the EKS cluster"
  value       = module.eks.cluster_security_group_id
}
```

| Output | Used by |
|---|---|
| `oidc_provider_arn`, `cluster_oidc_issuer_url` | IAM module (Lab 5) — IRSA trust policies |
| `node_security_group_id` | RDS module (Lab 3) — allow PostgreSQL from EKS nodes |
| `cluster_name`, `cluster_endpoint` | kubectl, CI/CD |

---

## Step 2.5 — Call the module from `envs/dev/main.tf`

```hcl
module "eks" {
  source = "../../modules/eks"

  project            = local.project
  env                = local.env
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnets
  kubernetes_version = "1.35"
  instance_types     = ["t3.small"]
  min_size           = 1
  max_size           = 5
  desired_size       = 4
}
```

**Critical wiring:**

```hcl
vpc_id     = module.vpc.vpc_id
subnet_ids = module.vpc.private_subnets
```

EKS does not create a VPC — it receives IDs from the VPC module's **outputs**.

---

## Step 2.6 — Add output to `envs/dev/output.tf`

```hcl
output "eks_cluster_name" {
  value = module.eks.cluster_name
}
```

---

## Step 2.7 — Verify

```bash
cd envs/dev
terraform init -upgrade
terraform plan
```

Expect EKS cluster, node group, OIDC provider, addons — ~15+ resources. **First apply takes ~15 minutes.**

Optional apply + kubectl test:

```bash
terraform apply
aws eks update-kubeconfig --region us-east-1 --name pharma-dev-cluster
kubectl get nodes
```

---

## Teaching Points

| Question | Answer |
|---|---|
| Why private subnets for EKS nodes? | Worker nodes should not have public IPs |
| Why `enable_irsa`? | Lets pods assume IAM roles without static AWS keys |
| Why not put VPC inside EKS module? | Separation of concerns — VPC is reusable without EKS |
| What if I swap `private_subnets` for `public_subnets`? | Bad practice — nodes exposed to internet |

---

## Optional — Kubernetes provider

**Skip this unless you plan to manage Kubernetes resources with Terraform** (namespaces, service accounts, Helm releases, etc.). This project creates the EKS cluster via the AWS provider only. ArgoCD, External Secrets, and app deploys are handled by scripts outside Terraform.

If you need it later, add to `envs/dev/providers.tf`:

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}
```

Without any `kubernetes_*` resources in your `.tf` files, this provider is never used.

---

## Checkpoint

- [ ] `modules/eks/` created with variables, main, outputs
- [ ] Root passes `module.vpc.vpc_id` and `module.vpc.private_subnets`
- [ ] `terraform plan` shows VPC + EKS resources
- [ ] (Optional) `kubectl get nodes` shows Ready nodes

**Next:** [Lab 3 — RDS](03-rds.md) — uses VPC + EKS outputs
