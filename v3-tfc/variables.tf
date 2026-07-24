variable "location" {
  description = "Azure region to deploy into"
  type        = string
  default     = "eastus"
}

variable "project_name" {
  description = "Base name used to build resource names (letters/numbers/hyphens only)"
  type        = string
  default     = "sre-takehome"
}

variable "environment" {
  description = "Environment tag applied to all resources"
  type        = string
  default     = "hcf"
}

variable "secret_one_value" {
  description = "Value for the first secret associated with the container app (e.g. a sample API key). Never commit a real value here -- pass via TF_VAR_secret_one_value, a gitignored .tfvars file, or (for remote runs) a sensitive HCP Terraform workspace variable."
  type        = string
  sensitive   = true
}

variable "secret_two_value" {
  description = "Value for the second secret associated with the container app (e.g. a sample shared token). Never commit a real value here -- pass via TF_VAR_secret_two_value, a gitignored .tfvars file, or (for remote runs) a sensitive HCP Terraform workspace variable."
  type        = string
  sensitive   = true
}
