# Lab 3 — RDS PostgreSQL

**Goal:** Create `modules/rds/` and call it from `envs/dev/main.tf`, wired to VPC and EKS outputs.

**Depends on:** [Lab 1 — VPC](01-vpc.md), [Lab 2 — EKS](02-eks.md)

**Reference in repo:** [`modules/rds/`](../../modules/rds/)

---

## What You Are Building

| Setting | Dev value |
|---|---|
| Engine | PostgreSQL 17 |
| Instance class | `db.t3.micro` |
| Storage | 20 GB gp3, encrypted |
| Database name | `pharmadb` |
| Master user | `pharmaadmin` |
| Network | Private database subnets only |
| Access | Port 5432 from EKS node security group only |

---

## Step 3.1 — Create the module folder

```bash
mkdir -p modules/rds
```

---

## Step 3.2 — Write `modules/rds/variables.tf`

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
  description = "VPC ID for the RDS security group"
  type        = string
}

variable "db_subnet_group_name" {
  description = "Name of the DB subnet group"
  type        = string
}

variable "eks_node_security_group_id" {
  description = "Security group ID of EKS nodes to allow RDS access"
  type        = string
}

variable "db_name" {
  description = "Name of the database to create"
  type        = string
  default     = "pharmadb"
}

variable "username" {
  description = "Master username for the database"
  type        = string
}

variable "password" {
  description = "Master password for the database"
  type        = string
  sensitive   = true
}

variable "password_version" {
  description = "Increment to trigger a password update"
  type        = number
  default     = 1
}

variable "instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Allocated storage in GB"
  type        = number
  default     = 20
}

variable "multi_az" {
  description = "Enable Multi-AZ deployment"
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip final snapshot on deletion"
  type        = bool
  default     = true
}

variable "backup_retention_period" {
  description = "Number of days to retain backups"
  type        = number
  default     = 0
}

variable "deletion_protection" {
  description = "Enable deletion protection"
  type        = bool
  default     = false
}
```

---

## Step 3.3 — Write `modules/rds/main.tf`

RDS needs a security group before the database. Both live in this module:

```hcl
resource "aws_security_group" "rds" {
  name        = "${var.project}-${var.env}-rds-sg"
  description = "Security group for RDS PostgreSQL instance"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS worker nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.eks_node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project}-${var.env}-rds-sg"
    Project = var.project
    Env     = var.env
  }
}

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 7.0"

  identifier = "${var.project}-${var.env}-postgres"

  engine               = "postgres"
  engine_version       = "17.9"
  family               = "postgres17"
  major_engine_version = "17"
  instance_class       = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"

  db_name                     = var.db_name
  username                    = var.username
  manage_master_user_password = false
  password_wo                 = var.password
  password_wo_version         = var.password_version

  multi_az               = var.multi_az
  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = [aws_security_group.rds.id]

  skip_final_snapshot     = var.skip_final_snapshot
  backup_retention_period = var.backup_retention_period
  storage_encrypted       = true
  deletion_protection     = var.deletion_protection
  publicly_accessible     = false

  create_db_option_group = false

  tags = {
    Name    = "${var.project}-${var.env}-postgres"
    Project = var.project
    Env     = var.env
  }
}
```

**Three-way wiring inside the module:**

| Input | Source (from root) | Why |
|---|---|---|
| `vpc_id` | `module.vpc.vpc_id` | SG lives in this VPC |
| `eks_node_security_group_id` | `module.eks.node_security_group_id` | Only EKS nodes can connect |
| `db_subnet_group_name` | `module.vpc.database_subnet_group_name` | RDS in DB subnets |
| `password` | `var.db_password` | Secret from variable, not hardcoded |

---

## Step 3.4 — Write `modules/rds/outputs.tf`

```hcl
output "db_instance_endpoint" {
  description = "Connection endpoint for the RDS instance (hostname:port)"
  value       = module.rds.db_instance_endpoint
}

output "db_instance_address" {
  description = "Hostname of the RDS instance (without port)"
  value       = module.rds.db_instance_address
}

output "db_instance_port" {
  description = "Port of the RDS instance"
  value       = module.rds.db_instance_port
}

output "db_instance_name" {
  description = "Name of the database"
  value       = module.rds.db_instance_name
}
```

**Why `db_instance_address`?** Secrets Manager module (Lab 6) stores the DB hostname alongside credentials.

---

## Step 3.5 — Call the module from `envs/dev/main.tf`

```hcl
module "rds" {
  source = "../../modules/rds"

  project                    = local.project
  env                        = local.env
  username                   = "pharmaadmin"
  password                   = var.db_password
  vpc_id                     = module.vpc.vpc_id
  db_subnet_group_name       = module.vpc.database_subnet_group_name
  eks_node_security_group_id = module.eks.node_security_group_id
}
```

---

## Step 3.6 — Add output to `envs/dev/output.tf`

```hcl
output "rds_endpoint" {
  value = module.rds.db_instance_endpoint
}
```

---

## Step 3.7 — Verify

```bash
cd envs/dev
terraform plan \
  -var="db_password=ChangeMe123!" \
  -var="jwt_secret=dummy-for-now"
```

---

## Teaching Points

| Question | Answer |
|---|---|
| Why a separate security group? | Fine-grained control — only EKS nodes, not the whole VPC CIDR |
| Why `password_wo` not `password`? | Write-only attribute — password not stored in Terraform state in plain text |
| Why `publicly_accessible = false`? | Database must never be on the public internet |
| Why depends on EKS? | We need the node SG ID before we can write the ingress rule |

---

## Checkpoint

- [ ] `modules/rds/` created
- [ ] Root wires VPC + EKS outputs into RDS module
- [ ] Password passed via `-var`, never committed to Git
- [ ] Plan shows RDS instance + security group

**Next:** [Lab 4 — ECR](04-ecr.md)
