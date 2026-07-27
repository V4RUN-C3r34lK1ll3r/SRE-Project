### Resource group ###############################################

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.project_name}-${var.environment}"
  location = var.location
}

### Networking for private Redis connectivity #######################
# AKS needs to be in the same VNet as Redis's private endpoint to reach
# it privately -- unlike Container Apps, this doesn't have to be set at
# cluster creation, but it's simplest to wire up from the start.

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.project_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "aks_nodes" {
  name                 = "snet-aks-nodes"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.0.0.0/23"]
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.0.2.0/27"]
}

### AKS cluster #####################################################
# Single small node, Free control-plane tier -- this is a short-lived
# demo cluster (applied briefly, screenshotted, destroyed), not sized
# for anything real. The Key Vault Secrets Provider addon is AKS's
# built-in Secrets Store CSI driver integration: it provisions its own
# managed identity, which is granted read access to the Key Vault
# below -- the exact same identity/RBAC pattern as v1, just handed to
# a cluster addon instead of a container app.

resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${var.project_name}-${var.environment}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = "aks-${var.project_name}-${var.environment}"
  sku_tier            = "Free"

  default_node_pool {
    name           = "default"
    node_count     = 1
    vm_size        = var.node_vm_size
    vnet_subnet_id = azurerm_subnet.aks_nodes.id
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
    # AKS's default Kubernetes service CIDR (10.0.0.0/16) overlaps our own
    # VNet address space, so it's pinned to a range outside 10.0.0.0/16.
    service_cidr   = "10.100.0.0/16"
    dns_service_ip = "10.100.0.10"
  }

  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }
}

### Key Vault ######################################################
# Same RBAC-authorized pattern as v1: one role assignment lets the
# Terraform caller write secrets, one lets a consumer identity read
# them. The consumer here is the AKS Key Vault Secrets Provider
# addon's identity rather than a container app's user-assigned
# identity -- everything downstream of that (the Deployment reading a
# Kubernetes Secret synced from this vault) lives in the Helm chart,
# not in Terraform, so ArgoCD owns it going forward, not this state
# file.

# Key Vault names are globally unique across every Azure tenant, not just
# this subscription -- a plain project+env name works until it collides
# with someone else's vault. This suffix is the standard, cheap guard.
resource "random_string" "kv_suffix" {
  length  = 4
  special = false
  upper   = false
}

resource "azurerm_key_vault" "this" {
  name                       = "kv-${substr(replace(var.project_name, "-", ""), 0, 10)}${substr(var.environment, 0, 3)}${random_string.kv_suffix.result}"
  resource_group_name        = azurerm_resource_group.this.name
  location                   = azurerm_resource_group.this.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = false # true in a real environment; false here so the exercise vault is easy to tear down
  soft_delete_retention_days = 7
}

resource "azurerm_role_assignment" "terraform_caller_kv_officer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Lets the AKS Key Vault Secrets Provider addon's identity *read*
# secrets at runtime -- this is what the SecretProviderClass in the
# Helm chart authenticates as when it syncs secrets into the cluster.
resource "azurerm_role_assignment" "aks_kv_reader" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_kubernetes_cluster.this.key_vault_secrets_provider[0].secret_identity[0].object_id
}

resource "azurerm_key_vault_secret" "secret_one" {
  name         = "secret-one"
  value        = var.secret_one_value
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [azurerm_role_assignment.terraform_caller_kv_officer]
}

resource "azurerm_key_vault_secret" "secret_two" {
  name         = "secret-two"
  value        = var.secret_two_value
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [azurerm_role_assignment.terraform_caller_kv_officer]
}

### Redis, private-only, reached via the VNet above #################
# Azure Cache for Redis has no free tier -- meant to be applied briefly
# to confirm it works, then destroyed. public_network_access_enabled =
# false means the only way in is through the private endpoint below.

resource "azurerm_redis_cache" "this" {
  name                          = "redis-${var.project_name}-${var.environment}"
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  capacity                      = 0
  family                        = "C"
  sku_name                      = "Basic"
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false
}

resource "azurerm_private_dns_zone" "redis" {
  name                = "privatelink.redis.cache.windows.net"
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "redis" {
  name                  = "link-${var.project_name}-${var.environment}"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.redis.name
  virtual_network_id    = azurerm_virtual_network.this.id
}

resource "azurerm_private_endpoint" "redis" {
  name                = "pe-redis-${var.project_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "psc-redis"
    private_connection_resource_id = azurerm_redis_cache.this.id
    subresource_names              = ["redisCache"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.redis.id]
  }
}

# Same pattern as the two app secrets above -- read straight off the
# resource Terraform just created, synced into the cluster the same way
# by the same SecretProviderClass, no separate wiring needed on the k8s
# side beyond adding one more entry to it.
resource "azurerm_key_vault_secret" "redis_connection_string" {
  name         = "redis-connection-string"
  value        = azurerm_redis_cache.this.primary_connection_string
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [azurerm_role_assignment.terraform_caller_kv_officer]
}
