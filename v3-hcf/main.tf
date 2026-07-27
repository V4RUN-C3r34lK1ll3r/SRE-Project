### Resource group ###############################################

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.project_name}-${var.environment}"
  location = var.location
}

### Networking for private Redis connectivity #######################
# Container Apps environments only reach private endpoints (like a
# private-only Redis cache) if VNet-integrated -- and that has to be set
# at environment *creation*, not added later. Two subnets: one delegated
# to the Container Apps environment itself, one for the Redis private
# endpoint.

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.project_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "container_apps" {
  name                 = "snet-container-apps"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.0.0.0/23"]

  delegation {
    name = "Microsoft.App/environments"
    service_delegation {
      name = "Microsoft.App/environments"
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.0.2.0/27"]
}

### Observability backend for the Container Apps environment #####
# Container Apps environments require a Log Analytics workspace for
# their built-in log streaming / diagnostic sink, even before you
# wire up anything fancier (Application Insights, alerts, etc).

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.project_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_container_app_environment" "this" {
  name                       = "cae-${var.project_name}-${var.environment}"
  resource_group_name        = azurerm_resource_group.this.name
  location                   = azurerm_resource_group.this.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  infrastructure_subnet_id   = azurerm_subnet.container_apps.id
}

### Identity used by the Container App to read Key Vault secrets ##
# A user-assigned identity (rather than system-assigned) so the
# identity's lifecycle is decoupled from the container app itself --
# useful if the app is ever recreated, and it's the same pattern
# we'd reuse later to let the app reach a private Redis instance.

resource "azurerm_user_assigned_identity" "container_app" {
  name                = "id-${var.project_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
}

### Key Vault ######################################################
# RBAC authorization (not legacy access policies) so access is just
# ordinary role assignments -- one for the app's identity to *read*
# secrets, one for the Terraform caller to *write* them.

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

# Lets whoever runs `terraform apply` create/update secrets.
resource "azurerm_role_assignment" "terraform_caller_kv_officer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Lets the container app's identity *read* secrets at runtime.
resource "azurerm_role_assignment" "container_app_kv_reader" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.container_app.principal_id
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
# Azure Cache for Redis has no free tier -- this is meant to be applied
# briefly to confirm it works, then destroyed. public_network_access_enabled
# = false means the only way in is through the private endpoint below;
# there is no public address to accidentally expose.

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

# Lets the container app's environment resolve the Redis hostname to the
# private endpoint's IP instead of a public one -- without this, DNS still
# resolves to Redis's public FQDN even though public access is disabled.
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

# Same pattern as the two app secrets above -- the connection string never
# sits in a variable or a committed file, it's read straight off the
# resource Terraform just created and handed to Key Vault directly.
resource "azurerm_key_vault_secret" "redis_connection_string" {
  name         = "redis-connection-string"
  value        = azurerm_redis_cache.this.primary_connection_string
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [azurerm_role_assignment.terraform_caller_kv_officer]
}

### Container App ###################################################
# Two containers (nginx placeholder image per the assignment), each
# with one Key Vault-backed secret surfaced as an env var.

resource "azurerm_container_app" "this" {
  name                         = "ca-${var.project_name}-${var.environment}"
  resource_group_name          = azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.container_app.id]
  }

  secret {
    name                = "secret-one"
    identity            = azurerm_user_assigned_identity.container_app.id
    key_vault_secret_id = azurerm_key_vault_secret.secret_one.versionless_id
  }

  secret {
    name                = "secret-two"
    identity            = azurerm_user_assigned_identity.container_app.id
    key_vault_secret_id = azurerm_key_vault_secret.secret_two.versionless_id
  }

  secret {
    name                = "redis-connection-string"
    identity            = azurerm_user_assigned_identity.container_app.id
    key_vault_secret_id = azurerm_key_vault_secret.redis_connection_string.versionless_id
  }

  template {
    container {
      name   = "web"
      image  = "nginx:latest"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name        = "APP_SECRET"
        secret_name = "secret-one"
      }

      env {
        name        = "REDIS_CONNECTION_STRING"
        secret_name = "redis-connection-string"
      }
    }

    container {
      name   = "sidecar"
      image  = "nginx:latest"
      cpu    = 0.25
      memory = "0.5Gi"
      # Containers in the same Container App revision share a network
      # namespace, same as pods in Kubernetes. Both containers defaulting
      # to nginx would both try to bind 0.0.0.0:80 and crash-loop -- this
      # command override keeps the sidecar as a placeholder second
      # container without it fighting the "web" container for the port.
      command = ["sleep", "infinity"]

      env {
        name        = "SIDECAR_SECRET"
        secret_name = "secret-two"
      }
    }
  }

  ingress {
    external_enabled = true
    target_port      = 80

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  depends_on = [
    azurerm_role_assignment.container_app_kv_reader,
  ]

  # The provider docs call this out explicitly: when a secret uses
  # key_vault_secret_id, Terraform can't diff the underlying value
  # (it lives in Key Vault, not state), so without this it shows a
  # perpetual planned change on every run.
  lifecycle {
    ignore_changes = [secret]
  }
}
