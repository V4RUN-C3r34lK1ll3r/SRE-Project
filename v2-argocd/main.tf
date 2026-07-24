### Resource group ###############################################

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.project_name}-${var.environment}"
  location = var.location
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
    name       = "default"
    node_count = 1
    vm_size    = var.node_vm_size
  }

  identity {
    type = "SystemAssigned"
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
