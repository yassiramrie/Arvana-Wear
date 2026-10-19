variable "aws_region" {
  description = "AWS region for this environment."
  type        = string
  default     = "ap-southeast-3"
}

variable "environment" {
  description = "Environment name; use a separate state for each environment."
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,12}$", var.environment))
    error_message = "environment must contain 2-12 lowercase letters, digits, or hyphens."
  }
}

variable "name_prefix" {
  description = "Prefix for AWS resource names."
  type        = string
  default     = "arvana-wear"
}

variable "github_repository" {
  description = "GitHub owner/repository allowed to publish images."
  type        = string
  default     = "yassiramrie/Arvana-Wear"
}

variable "github_branch" {
  description = "Only this branch may assume the GitHub Actions publishing role."
  type        = string
  default     = "main"
}

variable "vpc_cidr" {
  description = "IPv4 CIDR for the environment VPC."
  type        = string
  default     = "10.40.0.0/16"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "Trusted public IPv4 CIDRs allowed to access the EKS API; set to your static IP with /32."
  type        = list(string)
  default     = []

  validation {
    condition = length(var.cluster_endpoint_public_access_cidrs) > 0 && alltrue([
      for cidr in var.cluster_endpoint_public_access_cidrs :
      try(cidrnetmask(cidr) != "" && tonumber(split("/", cidr)[1]) >= 16, false)
    ])
    error_message = "Set at least one valid trusted IPv4 CIDR and do not allow 0.0.0.0/0."
  }
}

variable "kubernetes_version" {
  description = "EKS Kubernetes control plane version."
  type        = string
  default     = "1.35"
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_min_size" {
  description = "Minimum number of EKS worker nodes."
  type        = number
  default     = 2

  validation {
    condition     = floor(var.node_min_size) == var.node_min_size && var.node_min_size >= 1
    error_message = "node_min_size must be a positive integer."
  }
}

variable "node_desired_size" {
  description = "Initial number of EKS worker nodes."
  type        = number
  default     = 2

  validation {
    condition     = floor(var.node_desired_size) == var.node_desired_size && var.node_desired_size >= 1
    error_message = "node_desired_size must be a positive integer."
  }
}

variable "node_max_size" {
  description = "Maximum number of EKS worker nodes."
  type        = number
  default     = 4

  validation {
    condition     = floor(var.node_max_size) == var.node_max_size && var.node_max_size >= 1
    error_message = "node_max_size must be a positive integer."
  }
}

variable "postgres_engine_version" {
  description = "PostgreSQL engine version for RDS."
  type        = string
  default     = "16"
}

variable "database_instance_class" {
  description = "RDS instance class; choose based on workload and regional availability."
  type        = string
  default     = "db.t4g.micro"
}

variable "database_multi_az" {
  description = "Enable Multi-AZ database standby (additional cost)."
  type        = bool
  default     = false
}

variable "database_backup_retention_period" {
  description = "RDS automated backup retention in days; 0 disables backups for disposable development."
  type        = number
  default     = 0

  validation {
    condition     = floor(var.database_backup_retention_period) == var.database_backup_retention_period && var.database_backup_retention_period >= 0 && var.database_backup_retention_period <= 35
    error_message = "database_backup_retention_period must be an integer from 0 to 35."
  }
}

variable "database_deletion_protection" {
  description = "Enable RDS deletion protection; keep disabled only for disposable dev environments."
  type        = bool
  default     = false
}

variable "database_skip_final_snapshot" {
  description = "Skip final RDS snapshot when destroying a disposable dev environment."
  type        = bool
  default     = true
}

variable "database_pool_max" {
  description = "Maximum PostgreSQL connections per API pod."
  type        = number
  default     = 5

  validation {
    condition     = floor(var.database_pool_max) == var.database_pool_max && var.database_pool_max >= 1
    error_message = "database_pool_max must be a positive integer."
  }
}

variable "application_origin" {
  description = "Explicit HTTP or HTTPS origin allowed by the API, e.g. http://localhost or the public load balancer hostname."
  type        = string

  validation {
    condition     = can(regex("^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$", var.application_origin))
    error_message = "application_origin must be one HTTP or HTTPS hostname origin without credentials, path, or query."
  }
}
