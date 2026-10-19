variable "aws_region" {
  description = "AWS region for the Terraform state bucket."
  type        = string
  default     = "ap-southeast-3"
}

variable "name_prefix" {
  description = "Short, globally unique prefix for the state bucket."
  type        = string
  default     = "arvana-wear"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,30}$", var.name_prefix))
    error_message = "name_prefix must contain 3-30 lowercase letters, digits, or hyphens."
  }
}
