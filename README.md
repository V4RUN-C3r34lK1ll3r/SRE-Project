# SRE Take-Home — Three Versions

Same brief — an Azure-hosted app running two containers with one or two
secrets associated with it — built three different ways to have a real
comparison ready for the interview discussion, not just a hypothetical one.

| | Compute | Delivery | State backend | Resource suffix |
|---|---|---|---|---|
| [v1-container-apps/](v1-container-apps/) | Azure Container Apps | `terraform apply` directly | Local | `-dev` |
| [v2-argocd/](v2-argocd/) | AKS | Helm chart synced by ArgoCD (GitOps) | Local | `-argocd` |
| [v3-tfc/](v3-tfc/) | Azure Container Apps | `terraform apply`, approved in the HCP Terraform UI | HCP Terraform (remote state, remote execution) | `-hcf` |

## Why three

- **v1** is the literal ask: Container Apps, two containers, Key Vault-backed
  secrets, `terraform init`/`validate` passing.
- **v2** answers "what would this look like on the stack your platform team
  actually runs" — AKS instead of a serverless container platform, secrets
  synced from Key Vault into Kubernetes natively, and delivery handled by
  ArgoCD reconciling a Helm chart instead of a direct `terraform apply`.
- **v3** answers "what changes if this needs to be run by a team, not a
  single laptop" — same infrastructure as v1, but state lives in HCP
  Terraform (remote, locked, versioned) instead of a local `.tfstate` file.

Each version is self-contained — its own `terraform init`/`validate`/`plan`
inside its own folder, its own README with the reasoning for that version
specifically. None of them share state with each other.

## Common ground across all three

- Secrets are never hardcoded and never sit in plaintext in Terraform state —
  Key Vault (v1/v3) or Key Vault synced into a native Kubernetes Secret (v2).
- Every version passes `terraform init` + `terraform validate` at minimum;
  each was also applied live and torn down afterward with `terraform
  destroy` to avoid ongoing cost — see each subfolder's README for what "live"
  actually looked like.
- All three share the same fixes for the same underlying gotchas: a
  `random_string` suffix on the Key Vault name (globally unique across
  Azure, not just this subscription), and a `command` override on the
  `sidecar` container so two containers sharing a network namespace don't
  both try to bind port 80. See each subfolder's README under "Known
  gotchas" for the specifics.
