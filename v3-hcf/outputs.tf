output "container_app_fqdn" {
  description = "Public FQDN of the container app"
  value       = azurerm_container_app.this.ingress[0].fqdn
}

output "container_app_identity_principal_id" {
  description = "Principal ID of the user-assigned identity attached to the container app"
  value       = azurerm_user_assigned_identity.container_app.principal_id
}

output "key_vault_uri" {
  description = "URI of the Key Vault holding the container app's secrets"
  value       = azurerm_key_vault.this.vault_uri
}

output "redis_hostname" {
  description = "Redis hostname -- only resolves to a real address from inside the VNet, via the private DNS zone"
  value       = azurerm_redis_cache.this.hostname
}

output "redis_private_endpoint_ip" {
  description = "Private IP the Redis hostname actually resolves to"
  value       = azurerm_private_endpoint.redis.private_service_connection[0].private_ip_address
}
