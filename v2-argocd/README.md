# v2 — AKS + ArgoCD (GitOps)

Same two-container, secrets-associated app as v1, rebuilt on the stack a
platform team running Kubernetes end-to-end would actually use: AKS instead
of a serverless container platform, and delivery handled by ArgoCD
reconciling a Helm chart instead of a direct `terraform apply`.

## Why this exists

The take-home asked for Container Apps specifically (see
[v1-container-apps/](../v1-container-apps/)). This version exists to have a
real, running comparison ready for the "what would this look like on a
Kubernetes-based platform" conversation, instead of answering from a
hypothetical.

## Deliberate design choice: Terraform stops at the cloud boundary

Terraform in this folder provisions **cloud infrastructure only** -- resource
group, AKS cluster, Key Vault, secrets, RBAC. It does **not** install ArgoCD
and does **not** define the Kubernetes Deployment, Service, or
SecretProviderClass -- those live in [chart/](chart/) and are applied by
ArgoCD, not by `terraform apply`.

This is deliberate, not a scope cut:

- Once ArgoCD is watching a cluster, anything Terraform also tries to manage
  inside that same cluster becomes a **reconciliation fight** -- ArgoCD's
  `selfHeal` will revert changes it didn't make, including Terraform's.
- It mirrors a real separation of concerns: **infrastructure lifecycle**
  (Terraform, changes rarely) vs. **application delivery lifecycle**
  (ArgoCD, changes on every merge). Different tools, different cadences, on
  purpose.
- It also sidesteps a genuine Terraform/ArgoCD gotcha worth knowing: the
  `kubernetes_manifest` resource does a schema-validated dry run against the
  cluster at plan time, which means it needs the CRD it's targeting (like
  ArgoCD's own `Application` CRD) to already exist -- a chicken-and-egg
  problem if the same `apply` both installs ArgoCD and defines an
  `Application` for it. Keeping ArgoCD's install and the `Application`
  manifest outside Terraform avoids that two-phase-apply headache entirely.

## What Terraform builds

- Resource group
- AKS cluster -- one `Standard_B2s` node, `sku_tier = "Free"` (no control
  plane SLA charge), Key Vault Secrets Provider addon enabled
- Key Vault (RBAC-authorized), two secrets
  - "Key Vault Secrets Officer" role → the Terraform caller (write)
  - "Key Vault Secrets User" role → the AKS addon's own managed identity
    (read) -- same RBAC pattern as v1, just handed to a cluster addon
    instead of a container app's identity

## What the Helm chart builds (synced by ArgoCD, not Terraform)

- `SecretProviderClass` -- tells the CSI driver which Key Vault secrets to
  pull, and mirrors them into a native Kubernetes `Secret` (`app-secrets`)
- `Deployment` -- one pod, two containers (`web`, `sidecar`), same shape as
  v1's container app, each reading one secret via `secretKeyRef`
- `Service` -- ClusterIP, for parity with v1's ingress

## Bootstrap (one-time, manual -- not Terraform)

```bash
cd v2-argocd
cp terraform.tfvars.example terraform.tfvars   # then edit, or use TF_VAR_* env vars
terraform init
terraform validate
terraform apply

# point kubectl/helm at the new cluster
$(terraform output -raw get_credentials_command)

# install ArgoCD itself
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd --namespace argocd --create-namespace

# wire the addon identity and Key Vault name into the chart, then apply the Application
CLIENT_ID=$(terraform output -raw key_vault_secrets_provider_client_id)
KV_NAME=$(terraform output -raw key_vault_name)
sed -e "s/REPLACE_WITH_TERRAFORM_OUTPUT_CLIENT_ID/$CLIENT_ID/" \
    -e "s/REPLACE_WITH_TERRAFORM_OUTPUT_KV_NAME/$KV_NAME/" \
    argocd-application.yaml | kubectl apply -f -
```

From there ArgoCD takes over: it syncs `chart/` from this repo, and any
future change to the chart on `main` gets reconciled automatically
(`prune: true`, `selfHeal: true`).

## Known gotchas

- **Containers sharing a network namespace**: a pod's containers share
  networking, same as containers in a single Container App revision (v1).
  Both containers defaulting to `nginx:latest` would both try to bind `:80`
  and one would crash-loop -- the `sidecar` container in
  [chart/templates/deployment.yaml](chart/templates/deployment.yaml)
  overrides its command to `["sleep", "infinity"]` to avoid this.
- **Key Vault name collisions**: vault names are globally unique across
  every Azure tenant. The name includes a random 4-character suffix
  (`random_string.kv_suffix`), which also means it **can't be hardcoded**
  in `chart/values.yaml` -- it has to flow from `terraform output
  key_vault_name` into the ArgoCD `Application`'s helm values, same as the
  addon's client ID already does.
- **RBAC propagation delay**: same risk as v1 -- a fresh `apply` can
  occasionally 403 on the first secret write even with `depends_on`
  ordering the API calls correctly, since the role assignment itself can
  take a minute or two to propagate. A second `apply` fixes it.

## Cost notes

Everything here is meant to run briefly for a demo, then be torn down with
`terraform destroy` -- unlike v1, this version has an **always-on cost**
while it exists (the AKS node VM bills per hour regardless of use; the
control plane itself is free on the `Free` SKU tier). A single `Standard_B2s`
node for a short demo session is a small fraction of a dollar, but don't
leave it running.

## How this compares to v1

| | v1 (Container Apps) | v2 (this version) |
|---|---|---|
| Compute | Serverless, consumption-billed | AKS node pool, billed whether idle or not |
| Delivery | `terraform apply` deploys the app directly | ArgoCD reconciles a Helm chart from git -- Terraform never touches the running app |
| Secrets | Key Vault → container app via `key_vault_secret_id` | Key Vault → Kubernetes `Secret` via the CSI driver's `SecretProviderClass` |
| Drift correction | None built in | Automatic -- ArgoCD's `selfHeal` reverts manual changes |
| Operational overhead | Near zero | A cluster to patch, upgrade, and pay for |
