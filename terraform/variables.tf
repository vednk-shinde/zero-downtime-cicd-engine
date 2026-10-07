variable "name" {
  description = "Project name prefix for all resources"
  type        = string
  default     = "zdt"
}

variable "environment" {
  description = "dev | staging | prod"
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "kubernetes_version" {
  type    = string
  default = "1.31"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_min" {
  type    = number
  default = 2
}

variable "node_max" {
  type    = number
  default = 6
}

variable "node_desired" {
  type    = number
  default = 3
}

variable "github_repository" {
  description = "owner/repo allowed to assume the deploy role via OIDC"
  type        = string
  default     = "vednk-shinde/zero-downtime-cicd-engine"
}

variable "create_github_oidc_provider" {
  description = "Set false if the account already has the GitHub OIDC provider"
  type        = bool
  default     = true
}

variable "github_oidc_provider_arn" {
  description = "Existing provider ARN, used when create_github_oidc_provider = false"
  type        = string
  default     = ""
}
