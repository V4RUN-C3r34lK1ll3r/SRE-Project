output "aks_cluster_name" {
  description = "Name of the AKS cluster"
  value       = azurerm_kubernetes_cluster.this.name
}

output "resource_group_name" {
  description = "Resource group holding every resource in this version"
  value       = azurerm_resource_group.this.name
}

output "get_credentials_command" {
  description = "Run this to point kubectl/helm at the new cluster"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.this.name} --name ${azurerm_kubernetes_cluster.this.name} --overwrite-existing"
}

output "key_vault_uri" {
  description = "URI of the Key Vault holding the app's secrets"
  value       = azurerm_key_vault.this.vault_uri
}

output "key_vault_name" {
  description = "Name of the Key Vault -- includes a random suffix, so it can't be hardcoded. Consumed by ../app/ as the Application's keyVault.name helm parameter."
  value       = azurerm_key_vault.this.name
}

output "key_vault_secrets_provider_client_id" {
  description = "Client ID of the AKS Key Vault Secrets Provider addon's managed identity. Consumed by ../app/ as keyVault.userAssignedIdentityID."
  value       = azurerm_kubernetes_cluster.this.key_vault_secrets_provider[0].secret_identity[0].client_id
}

output "tenant_id" {
  description = "Azure AD tenant ID. Consumed by ../app/ as keyVault.tenantId -- not hardcoded in the chart so it isn't tied to one specific tenant."
  value       = data.azurerm_client_config.current.tenant_id
}

# Everything below exists solely so ../app/ can build its own `kubernetes`
# provider (to manage the ArgoCD Application resource) via
# terraform_remote_state, without re-deriving cluster credentials itself.
# Same values `platform/`'s own kubernetes/helm providers already use --
# just surfaced as outputs. Marked sensitive: this is the same client
# certificate/key that `az aks get-credentials` would write to a kubeconfig
# file, now sitting in this root's state file instead.
output "kube_config_host" {
  description = "AKS cluster API server endpoint -- sensitive, consumed by ../app/'s kubernetes provider"
  value       = azurerm_kubernetes_cluster.this.kube_config[0].host
  sensitive   = true
}

output "kube_config_client_certificate" {
  description = "Base64-encoded client certificate for cluster auth -- sensitive, consumed by ../app/'s kubernetes provider"
  value       = azurerm_kubernetes_cluster.this.kube_config[0].client_certificate
  sensitive   = true
}

output "kube_config_client_key" {
  description = "Base64-encoded client key for cluster auth -- sensitive, consumed by ../app/'s kubernetes provider"
  value       = azurerm_kubernetes_cluster.this.kube_config[0].client_key
  sensitive   = true
}

output "kube_config_cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate -- sensitive, consumed by ../app/'s kubernetes provider"
  value       = azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate
  sensitive   = true
}
