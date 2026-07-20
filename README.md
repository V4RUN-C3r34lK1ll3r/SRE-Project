# SRE Take-Home: Azure Container App

Terraform that provisions an Azure Container App running two containers (public
`nginx` images as placeholders), backed by Key Vault-managed secrets.

## What this builds

- Resource group
- Log Analytics workspace + Container Apps environment (log sink for the
  environment's built-in log streaming)
- User-assigned managed identity for the container app
- Key Vault (RBAC-authorized) with two secrets
  - one role assignment lets the Terraform caller write secrets
  - one role assignment lets the container app's identity read secrets
- Container App with two containers, each pulling one secret in as an
  environment variable via a Key Vault-backed `secret` block

## Why Key Vault instead of native container app secrets

A native `secret { value = ... }` block on the container app is simpler, but
the value sits in Terraform state in plaintext with no rotation story. Using
`azurerm_key_vault_secret` + `key_vault_secret_id` on the container app means
state only ever holds a reference, and access is controlled by ordinary RBAC
role assignments through the identity already attached to the app.

One quirk worth knowing: once a `secret` block references
`key_vault_secret_id`, Terraform can't diff the underlying value (it lives in
Key Vault, not state), so without `lifecycle { ignore_changes = [secret] }`
on the container app resource, every `plan` shows a spurious pending change.
That's handled in [main.tf](main.tf).

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # then edit, or use TF_VAR_* env vars
terraform init
terraform validate
terraform plan
```

Secrets are marked `sensitive` and have no default — set them via
`TF_VAR_secret_one_value` / `TF_VAR_secret_two_value` or a gitignored
`.tfvars` file. Never commit real values.

## Cost notes

Container Apps consumption plan and Log Analytics both have an always-free
monthly grant that easily covers a short-lived test of this stack. Key Vault
has no free tier but bills per-operation (fractions of a cent for a test
run). Managed identities and role assignments are free.

## Stretch topics (not built here, for discussion)

**Observability**: Container Apps' built-in log streaming for a quick tail;
a `diagnostic_setting` on the environment routing logs to the Log Analytics
workspace already provisioned here; Azure Monitor metric alerts on
CPU/memory/replica count; Application Insights if request-level tracing is
needed.

**Connectivity to a Redis cache**: VNet-integrate the Container Apps
environment, deploy `azurerm_redis_cache` inside that VNet, expose it via a
private endpoint + private DNS zone so the app never resolves a public
address, and surface the connection string as a Key Vault secret using the
same identity/role-assignment pattern already in place for the two secrets
above.
