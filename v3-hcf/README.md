# v3 — Same Infra, HCP Terraform (Remote State)

Identical infrastructure to [v1-container-apps/](../v1-container-apps/) --
`main.tf` here is a byte-for-byte copy. The only thing that changes is
**where state lives and how `apply` runs**: a local `.tfstate` file plus a
local `terraform apply` (v1) vs. HCP Terraform's managed backend with
**remote execution** (this version), with resources suffixed `-hcf` instead
of `-dev` to keep them distinguishable side by side.

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
    organization = "varunzackv"
    workspaces {
      name = "SRE-Project"
    }
  }
  # ...same required_providers block as v1, plus hashicorp/random
}
```

That's it on the Terraform side. Everything in `main.tf` is unchanged.

## Execution mode: remote, chosen deliberately

HCP Terraform workspaces run in one of two modes:

- **Remote** (used here) -- `plan`/`apply` execute on HCP Terraform's own
  runners, approved in the web UI. The runner has no `az login` session, so
  it needs its own Azure credential -- a **service principal**
  (`sp-sre-takehome-tfc`), granted Contributor plus User Access
  Administrator (scoped by an Azure Condition to exclude Owner/UAA/RBAC-admin
  roles), with `ARM_CLIENT_ID` / `ARM_CLIENT_SECRET` / `ARM_TENANT_ID` /
  `ARM_SUBSCRIPTION_ID` stored as workspace variables. This is the fuller,
  more authentic HCP Terraform story -- run history, UI-driven approval, a
  workspace a whole team could use.
- **Local** -- HCP Terraform stores and locks *state only*; `plan`/`apply`
  still run on your own machine with your existing `az` session. Simpler,
  no service principal needed, and still delivers the core "shared, locked,
  versioned state" story -- a legitimate lighter-weight choice if remote
  execution's extra setup isn't worth it for a given team.

Workspace created via the **Version Control Workflow** (linked directly to
this GitHub repo), which is why it's named `SRE-Project` rather than the
`sre-takehome-hcf` name a CLI-driven workspace would have used -- the code
was updated to match what was actually created rather than force a rename.
**Terraform Working Directory** is set to `v3-hcf` on the workspace (Settings
→ General), since this repo has three separate configs in three subfolders.
(This folder was renamed from `v3-tfc` to `v3-hcf` to match the `-hcf`
resource suffix -- if your workspace still points at `v3-tfc`, update it in
the TFC UI or the next run will find no `.tf` files.)

## Setup

1. Sign up at [app.terraform.io](https://app.terraform.io), create an
   organization, create a workspace linked to this repo.
2. Set the workspace's **Terraform Working Directory** to `v3-hcf`.
3. Set **Execution Mode** to **Remote**.
4. Create a service principal and grant it Contributor + User Access
   Administrator on the subscription (the latter needs an Azure Condition
   excluding Owner/UAA/RBAC-admin roles -- Azure requires this for any
   User Access Administrator grant).
5. Add workspace variables: `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`
   (sensitive), `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID` as environment
   variables; `secret_one_value`, `secret_two_value` as sensitive Terraform
   variables.
6. Push to `main` (or click **New run** in the UI) to trigger a plan, then
   **Confirm & Apply**.

## How this compares to v1

| | v1 (local state) | v3 (this version) |
|---|---|---|
| State storage | `.tfstate` on one machine | HCP Terraform, versioned, encrypted at rest |
| Locking | None -- two people running `apply` at once can corrupt state | Built in -- a second `apply` blocks until the first finishes |
| Secrets in state | None (Key Vault-backed, same as here) -- but if they ever were, a local file is worse than a managed backend either way | Same secret handling, safer backend |
| Collaboration | Whoever has the laptop | Any team member with workspace access |
| Audit trail | None | Full run history, who applied what and when |

## Known gotchas

Same as [v1](../v1-container-apps/README.md#known-gotchas) -- byte-identical
`main.tf` means the same RBAC propagation delay, the same container
network-namespace port collision (fixed with a `command` override on the
sidecar), and the same Key Vault global-uniqueness handling (a random
4-character suffix) all apply here too.

Specific to this version: **granting User Access Administrator via CLI is
the kind of action that should get flagged**, not run silently -- it's a
role that can grant any permission to anyone on its scope. It was granted
manually in the Azure Portal instead, which is also why Azure requires an
extra Conditions step for that specific role.

**`terraform apply` from the CLI is blocked entirely on this workspace**:
`Error: Apply not allowed for workspaces with a VCS connection`. A
VCS-linked TFC workspace allows CLI-driven `plan` (read-only, safe from
anywhere) but requires `apply` to originate from a VCS-driven run -- either
a git push, or a run queued directly in the TFC UI (**Actions → Start new
run**), approved via **Confirm & Apply** there. Confirmed live: applied and
later destroyed entirely through the TFC UI for this reason.

**The Terraform Working Directory setting doesn't follow a folder rename
automatically**: after `v3-tfc/` was renamed to `v3-hcf/` in git, the
workspace setting itself still pointed at the old path until updated by
hand in Settings → General -- a code-level rename and a live external
system's config are two different things, and it's easy to fix the first
and forget the second.

## Redis, applied via the service principal

`main.tf` includes the same VNet + private Redis + private endpoint setup
as v1 (see [v1's README](../v1-container-apps/README.md#redis-connectivity--how-it-actually-works-here)
for the full flow). No extra IAM was needed to support it -- the service
principal's existing Contributor role already covers creating VNets,
subnets, private endpoints, and the Redis cache itself; only Key Vault RBAC
role *assignments* needed the separate User Access Administrator grant.
Same cost note as v1: Redis has no free tier, apply briefly, destroy right
after confirming it works.
