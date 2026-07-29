variable "db_password" {
  description = "Master password for the RDS PostgreSQL database"
  type        = string
  sensitive   = true
}

variable "jwt_secret" {
  description = "JWT signing secret for the application"
  type        = string
  sensitive   = true
}

variable "github_org" {
  description = "go4rom"
  type        = string
  default     = "go4rom"
}

variable "github_org_id" {
  description = "Numeric GitHub organization/owner ID. Fetch via: curl https://api.github.com/orgs/<github_org>"
  type        = string
  default     = "283630436"
}

variable "github_repo_ids" {
  description = "Map of GitHub repo name to its numeric GitHub repository ID. Fetch via: curl https://api.github.com/repos/<github_org>/<repo>"
  type        = map(string)
  default = {
    "zen-pharma-frontend"     = "1235505603"
    "zen-pharma-backend"      = "1235515471"
    "zen-pharma-backend-lab1" = "1260221715"
  }
}
