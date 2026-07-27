# v1 — Azure Container App (baseline)

The literal ask from the take-home assignment: Terraform for an Azure Container
App running two containers (public `nginx` images as placeholders), backed by
Key Vault-managed secrets. See the [repo root README](../README.md) for how
this compares to v2 and v3.

## What this builds

- Resource group
- Virtual network with two subnets: one delegated to the Container Apps
  environment (VNet integration has to be set at environment *creation*,
  not added later), one for the Redis private endpoint
- Log Analytics workspace + Container Apps environment (log sink for the
  environment's built-in log streaming), VNet-integrated into the subnet
  above
- User-assigned managed identity for the container app
- Key Vault (RBAC-authorized) with three secrets
  - one role assignment lets the Terraform caller write secrets
  - one role assignment lets the container app's identity read secrets
- **Azure Cache for Redis** (Basic C0), `public_network_access_enabled =
  false` -- reachable only through the private endpoint below
- A private DNS zone (`privatelink.redis.cache.windows.net`) linked to the
  VNet, so the Redis hostname resolves to the private endpoint's IP instead
  of a public address
- A private endpoint connecting Redis into the private-endpoints subnet
- Container App with two containers, each pulling a secret in as an
  environment variable via a Key Vault-backed `secret` block -- including
  the Redis connection string on the `web` container

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

## Live results (confirmed on a real apply)

- Container App FQDN: `ca-sre-takehome-dev.ashymoss-60a28bfc.eastus.azurecontainerapps.io`
  (confirmed reachable, returned HTTP 200)
- Key Vault URI: `https://kv-sretakehomdevd632.vault.azure.net/`
- Redis hostname: `redis-sre-takehome-dev.redis.cache.windows.net`
- Redis private endpoint IP: `10.0.2.4`

Torn down with `terraform destroy` immediately after confirming -- 19
resources destroyed, nothing left running. The first attempt at this apply
actually failed after 22+ minutes with a transient Azure regional capacity
error (`ManagedEnvironmentCapacityHeavyUsageError`), which left an orphaned
`Failed`-state Container App Environment that had to be deleted manually
(`az containerapp env delete`) before a clean retry succeeded.

## Known gotchas

- **RBAC propagation delay**: the Key Vault secrets `depends_on` the
  "Secrets Officer" role assignment, so the *ordering* is correct, but Azure
  RBAC grants can take up to a minute or two to actually propagate. A fresh
  `apply` can occasionally 403 on the first secret write even though the
  role assignment API call already succeeded -- a second `apply` right after
  fixes it, since Terraform just resumes from where it left off.
- **Both containers sharing a network namespace**: containers in the same
  Container App revision share networking, the same model as pods in
  Kubernetes. Two containers both defaulting to `nginx:latest` would both
  try to bind `0.0.0.0:80` and one would crash-loop. The `sidecar` container
  overrides its command to `["sleep", "infinity"]` specifically to avoid
  this -- it's a placeholder second container, not meant to actually serve
  traffic.
- **Key Vault name collisions**: vault names are globally unique across
  *every* Azure tenant, not just this subscription. The name includes a
  random 4-character suffix (`random_string.kv_suffix`) so re-running this
  against the same defaults never collides with a prior run or anyone
  else's vault.

## Usage

```bash
cd v1-container-apps
cp terraform.tfvars.example terraform.tfvars   # then edit, or use TF_VAR_* env vars
terraform init
terraform validate
terraform plan
```

Secrets are marked `sensitive` and have no default — set them via
`TF_VAR_secret_one_value` / `TF_VAR_secret_two_value` or a gitignored
`.tfvars` file. Never commit real values.

## Cost notes

Container Apps consumption plan, Log Analytics, the VNet, subnets, and the
private endpoint all have an always-free grant or no meaningful cost for a
short-lived test. Key Vault bills per-operation (fractions of a cent).
**Redis is the exception** -- Azure Cache for Redis has no free tier at all;
Basic C0 runs about $0.02/hour. Meant to be applied briefly to confirm it
works end to end, then torn down with `terraform destroy` -- not left
running.

## Redis connectivity -- how it actually works here

1. The Container Apps environment is VNet-integrated (`infrastructure_subnet_id`),
   which has to be decided at environment creation.
2. Redis has `public_network_access_enabled = false` -- there is no public
   address to reach it through at all.
3. A private endpoint puts Redis inside the VNet's private-endpoints
   subnet; a private DNS zone makes the Redis hostname resolve to that
   endpoint's private IP instead of a public one.
4. The connection string is read straight off the `azurerm_redis_cache`
   resource and written to Key Vault as a third secret -- never touches a
   variable, a file, or Terraform state as plaintext.
5. The `web` container gets it as `REDIS_CONNECTION_STRING`, using the same
   Key Vault secret + managed identity pattern as the other two secrets.

## Observability (discussion topic, not built here)

Container Apps' built-in log streaming for a quick tail; a
`diagnostic_setting` on the environment routing logs to the Log Analytics
workspace already provisioned here; Azure Monitor metric alerts on
CPU/memory/replica count; Application Insights if request-level tracing is
needed.
