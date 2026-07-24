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
  description = "Name of the Key Vault -- includes a random suffix, so it can't be hardcoded in chart/values.yaml. Plug this in as keyVault.name."
  value       = azurerm_key_vault.this.name
}

output "key_vault_secrets_provider_client_id" {
  description = "Client ID of the AKS Key Vault Secrets Provider addon's managed identity -- plug this into chart/values.yaml as keyVault.userAssignedIdentityID"
  value       = azurerm_kubernetes_cluster.this.key_vault_secrets_provider[0].secret_identity[0].client_id
}
