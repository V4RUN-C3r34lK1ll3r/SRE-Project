# v3 — Same Infra, HCP Terraform (Remote State)

Identical infrastructure to [v1-container-apps/](../v1-container-apps/) --
`main.tf` and `outputs.tf` here are byte-for-byte copies. The only thing that
changes is **where state lives**: a local `.tfstate` file (v1) vs. HCP
Terraform's managed backend (this version), with resources suffixed
`-hcf` instead of `-dev` to keep them distinguishable side by side.

## Why this exists

v1 works fine for one person on one laptop. It stops working the moment a
second person needs to run `apply` -- there's no shared state, no locking,
and the state file (which can contain secret values, even though this
particular config keeps them in Key Vault instead) sits on a single machine
with no audit trail. This version answers "what changes for a team."

## What actually changes vs. v1

```hcl
terraform {
  cloud {
    organization = "<your org>"
    workspaces {
      name = "sre-takehome-hcf"
    }
  }
  # ...same required_providers block as v1
}
```

That's it on the Terraform side. Everything in `main.tf` is unchanged.

## Execution mode: local, deliberately

HCP Terraform workspaces run in one of two modes:

- **Remote** -- `plan`/`apply` execute on HCP Terraform's own runners, not
  your machine. This is the "real" team setup, but it means the runner has
  no `az login` session -- it needs its own Azure credentials, which means
  creating a **service principal** (an App Registration + client secret)
  and storing it as sensitive workspace variables (`ARM_CLIENT_ID`,
  `ARM_CLIENT_SECRET`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`). That's a real
  credential with subscription-level access, worth a deliberate decision
  before creating it, not something to spin up automatically for a demo.
- **Local** -- HCP Terraform stores and locks **state only**; `plan`/`apply`
  still run on your machine using the same `az` CLI session as v1. This
  already delivers the actual team-collaboration story (shared, locked,
  versioned state) without provisioning a new Azure credential just to
  prove the point.

**This version uses local execution mode.** Set it on the workspace after
creation: **Workspace → Settings → General → Execution Mode → Local.**
If asked in the interview "would you use remote execution in practice" --
yes, for a real team, alongside a service principal or (better) OIDC
federation so there's no long-lived secret at all; local mode here is a
deliberate scope decision for a demo, not a limitation of HCP Terraform.

## Setup

1. Sign up at [app.terraform.io](https://app.terraform.io), create an
   organization.
2. Put that organization name into `organization = "..."` in `versions.tf`.
3. `terraform login` -- opens a browser, generates a CLI token, stores it
   locally (never commit it).
4. `terraform init` -- this creates the `sre-takehome-hcf` workspace in your
   org automatically on first run.
5. In the HCP Terraform UI, set that workspace's **Execution Mode to
   Local** (see above).
6. Same as v1 from here:
   ```bash
   export TF_VAR_secret_one_value="demo-api-key-12345"
   export TF_VAR_secret_two_value="demo-shared-token-67890"
   terraform plan
   terraform apply
   ```

## How this compares to v1

| | v1 (local state) | v3 (this version) |
|---|---|---|
| State storage | `.tfstate` on one machine | HCP Terraform, versioned, encrypted at rest |
| Locking | None -- two people running `apply` at once can corrupt state | Built in -- a second `apply` blocks until the first finishes |
| Secrets in state | None (Key Vault-backed, same as here) -- but if they ever were, a local file is worse than a managed backend either way | Same secret handling, safer backend |
| Collaboration | Whoever has the laptop | Any team member with workspace access |
| Audit trail | None | Full run history, who applied what and when |
