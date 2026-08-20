# Lab 1 — VPC

**Goal:** Create `modules/vpc/` and call it from `envs/dev/main.tf`.

**Depends on:** [Lab 0 — Foundation](00-foundation.md)

**Reference in repo:** [`modules/vpc/`](../../modules/vpc/)

---

## What You Are Building

| Subnet type | CIDR (dev) | Purpose |
|---|---|---|
| Public | `10.0.1.0/24`, `10.0.2.0/24` | NAT Gateway, load balancers |
| Private (EKS) | `10.0.3.0/24`, `10.0.4.0/24` | EKS worker nodes |
| Database (RDS) | `10.0.5.0/24`, `10.0.6.0/24` | PostgreSQL |

VPC CIDR: `10.0.0.0/16`

---

## Step 1.1 — Create the module folder

```bash
mkdir -p modules/vpc
```

---

## Step 1.2 — Write `modules/vpc/variables.tf`

```hcl
variable "project" {
  description = "Project name"
  type        = string
}

variable "env" {
  description = "Environment name (dev, qa, prod)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (EKS)"
  type        = list(string)
}

variable "database_subnet_cidrs" {
  description = "CIDR blocks for database subnets (RDS)"
  type        = list(string)
}
```

**Why these inputs?** CIDR ranges change per environment. The module must not hardcode `10.0.0.0/16` — the caller decides.

---

## Step 1.3 — Write `modules/vpc/main.tf`

We use the community [terraform-aws-modules/vpc](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws) module inside our wrapper. A VPC needs subnets, route tables, IGW, NAT — dozens of resources. Your job is to pass the right inputs and export the right outputs.

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${var.project}-${var.env}-vpc"
  cidr = var.vpc_cidr

  azs              = ["${var.region}a", "${var.region}b"]
  public_subnets   = var.public_subnet_cidrs
  private_subnets  = var.private_subnet_cidrs
  database_subnets = var.database_subnet_cidrs

  enable_nat_gateway           = true
  single_nat_gateway           = true
  enable_dns_hostnames         = true
  enable_dns_support           = true
  create_database_subnet_group = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"                         = "1"
    "kubernetes.io/cluster/${var.project}-${var.env}-cluster" = "owned"
  }

  tags = {
    Project = var.project
    Env     = var.env
  }
}
```

---

## Step 1.4 — Write `modules/vpc/outputs.tf`

```hcl
output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "public_subnets" {
  description = "List of public subnet IDs"
  value       = module.vpc.public_subnets
}

output "private_subnets" {
  description = "List of private subnet IDs"
  value       = module.vpc.private_subnets
}

output "database_subnets" {
  description = "List of database subnet IDs"
  value       = module.vpc.database_subnets
}

output "database_subnet_group_name" {
  description = "Name of the database subnet group"
  value       = module.vpc.database_subnet_group_name
}
```

**Why these outputs?** EKS needs `vpc_id` and `private_subnets`. RDS needs `database_subnet_group_name`. Export only what downstream modules need.

---

## Step 1.5 — Call the module from `envs/dev/main.tf`

```hcl
module "vpc" {
  source = "../../modules/vpc"

  project               = local.project
  env                   = local.env
  region                = local.region
  vpc_cidr              = "10.0.0.0/16"
  public_subnet_cidrs   = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs  = ["10.0.3.0/24", "10.0.4.0/24"]
  database_subnet_cidrs = ["10.0.5.0/24", "10.0.6.0/24"]
}
```

Call the module from root:

```hcl
module "vpc" {
  source = "../../modules/vpc"
  # ... environment-specific inputs
}
```

---

## Step 1.6 — Add outputs to `envs/dev/output.tf`

```hcl
output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnets" {
  value = module.vpc.private_subnets
}
```

---

## Step 1.7 — Verify

```bash
cd envs/dev
terraform init -upgrade
terraform plan
```

You should see ~15–20 resources to add (VPC, subnets, NAT, routes, etc.).

Optional apply:

```bash
terraform apply
# Confirm in AWS Console: VPC → pharma-dev-vpc
```

---

## Teaching Points

| Question | Answer |
|---|---|
| Why not hardcode CIDRs in the module? | QA/prod may use different ranges |
| Why `database_subnet_group_name` output? | RDS module needs it in Lab 3 |
| Why Kubernetes subnet tags? | EKS and AWS Load Balancer Controller discover subnets via these tags |
| Why a wrapper module? | Adds project-specific defaults; community module does the heavy lifting |

---

## Checkpoint

- [ ] `modules/vpc/` has `main.tf`, `variables.tf`, `outputs.tf`
- [ ] `envs/dev/main.tf` calls `module "vpc"` with `source = "../../modules/vpc"`
- [ ] `terraform plan` shows VPC resources only (no EKS/RDS yet)

**Next:** [Lab 2 — EKS](02-eks.md) — uses `module.vpc.vpc_id` and `module.vpc.private_subnets`
