### Resource group ###############################################

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.project_name}-${var.environment}"
  location = var.location
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

resource "azurerm_key_vault" "this" {
  name                       = "kv-${substr(replace(var.project_name, "-", ""), 0, 10)}${substr(var.environment, 0, 3)}"
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
    }

    container {
      name   = "sidecar"
      image  = "nginx:latest"
      cpu    = 0.25
      memory = "0.5Gi"

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
