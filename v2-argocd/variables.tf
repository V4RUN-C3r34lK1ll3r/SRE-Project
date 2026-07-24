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
  description = "Environment suffix used when building resource names (e.g. rg-<project>-<environment>) -- not an Azure resource tag"
  type        = string
  default     = "argocd"
}

variable "node_vm_size" {
  description = "VM size for the single AKS node pool -- kept small since this is a short-lived demo cluster"
  type        = string
  default     = "Standard_B2s"
}

variable "secret_one_value" {
  description = "Value for the first secret associated with the app (e.g. a sample API key). Never commit a real value here -- pass via TF_VAR_secret_one_value or a gitignored .tfvars file."
  type        = string
  sensitive   = true
}

variable "secret_two_value" {
  description = "Value for the second secret associated with the app (e.g. a sample shared token). Never commit a real value here -- pass via TF_VAR_secret_two_value or a gitignored .tfvars file."
  type        = string
  sensitive   = true
}
