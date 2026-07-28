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

## Two Terraform roots, two different lifecycles

This folder is split into two independent Terraform roots, each with its
own state:

- **[platform/](platform/)** — resource group, VNet, AKS cluster, Key
  Vault, Redis, RBAC, and **ArgoCD itself** (installed via the `helm`
  provider's `helm_release` resource, not a manual command). This is
  infrastructure a platform team stands up and then leaves running --
  applied rarely, destroyed rarely.
- **[app/](app/)** — just the ArgoCD `Application` object that tells
  ArgoCD to sync [chart/](chart/) from this repo. Applied once platform/
  exists; cheap to redeploy or tear down on its own without touching the
  cluster or reinstalling ArgoCD.
- **[chart/](chart/)** — the actual Deployment/Service/SecretProviderClass.
  Never touched by Terraform at all, in either root. Once `app/` has
  applied once, changing the chart and pushing to `main` is enough --
  ArgoCD's own sync loop (`prune: true`, `selfHeal: true`) picks it up with
  zero Terraform involvement.

The payoff: after `platform/` is up, you can redeploy, tweak, or fully
tear down and recreate the *app* as many times as you want without ever
touching the cluster or reinstalling ArgoCD -- matching how a real platform
team runs ArgoCD (long-lived, provisioned once) versus how apps come and go
on top of it (via GitOps, constantly).

**This does not make AKS free to leave running** -- the node's per-hour
cost is unchanged regardless of how the code is organized. The practical
use is: apply `platform/` once before a demo/prep session and leave it up
for the session; iterate on `app/` and `chart/` freely during that window;
destroy `platform/` only when actually done. See "Cost notes" below.

### Why splitting the Application into its own root is safe

`kubernetes_manifest` does a schema-validated dry run against the live
cluster **at plan time** -- it needs the CRD it targets (ArgoCD's own
`Application` CRD) to already exist. Installing ArgoCD and defining an
`Application` for it in the *same* apply would be a chicken-and-egg
problem. Two separate root modules, always applied in order (`platform/`
first, `app/` second, as genuinely separate `terraform apply`
invocations), removes that problem structurally: by the time `app/` ever
plans, `platform/` has already finished and the CRD already exists.

One consequence worth knowing: `app/`'s `plan`/`apply` require the AKS
cluster to actually exist and be reachable right now. It can't be planned
against a destroyed or unreachable cluster -- expected, not a bug, since
`app/` only makes sense while `platform/` is up.

## What `platform/` builds

- Resource group
- Virtual network with a subnet for the AKS nodes (`network_plugin =
  "azure"`, so pods get real VNet IPs) and a subnet for the Redis private
  endpoint
- AKS cluster -- one `Standard_D2s_v3` node, `sku_tier = "Free"` (no control
  plane SLA charge), Key Vault Secrets Provider addon enabled, VNet-attached
  (originally `Standard_B2s`; switched after a live apply found it blocked
  by this subscription's allowed-VM-SKU policy -- see "Known gotchas" below)
- Key Vault (RBAC-authorized), three secrets
  - "Key Vault Secrets Officer" role → the Terraform caller (write)
  - "Key Vault Secrets User" role → the AKS addon's own managed identity
    (read) -- same RBAC pattern as v1, just handed to a cluster addon
    instead of a container app's identity
- **Azure Cache for Redis** (Basic C0), `public_network_access_enabled =
  false`, reachable only through a private endpoint in the subnet above,
  with a private DNS zone so the hostname resolves privately
- The Redis connection string, written straight to Key Vault as the third
  secret
- **ArgoCD** (`helm_release.argocd`, chart `argo/argo-cd`, namespace
  `argocd`) -- the `helm`/`kubernetes` providers authenticate straight off
  the AKS cluster's own `kube_config` output, no separate `az aks
  get-credentials` step needed for this to apply

## What `app/` builds

Exactly one resource: `kubernetes_manifest.argocd_application` -- the same
ArgoCD `Application` object previously applied by hand via `kubectl apply`
with `sed`-substituted values, now expressed as a native HCL object. It
reads `platform/`'s outputs (Key Vault name, the addon's client ID, tenant
ID) via a `terraform_remote_state` data source instead of copy-pasted
`terraform output` values, so there's no manual substitution step left at
all.

## What the Helm chart builds (synced by ArgoCD, never Terraform)

- `SecretProviderClass` -- tells the CSI driver which Key Vault secrets to
  pull (three), and mirrors them into a native Kubernetes `Secret`
  (`app-secrets`)
- `Deployment` -- one pod, two containers (`web`, `sidecar`), same shape as
  v1's container app; `web` reads `APP_SECRET` and `REDIS_CONNECTION_STRING`,
  `sidecar` reads `SIDECAR_SECRET`, all via `secretKeyRef`
- `Service` -- ClusterIP, for parity with v1's ingress

## Usage

```bash
# 1. Stand up the platform -- cluster + Key Vault + Redis + ArgoCD itself.
#    Rare: do this once per demo/prep session, leave it running.
cd v2-argocd/platform
cp terraform.tfvars.example terraform.tfvars   # then edit, or use TF_VAR_* env vars
terraform init
terraform apply

# 2. Point ArgoCD at this repo's chart. Usually applied once; only needs
#    re-running if the Application's own pointer config changes (repo URL,
#    path, sync policy) -- not for ordinary chart edits.
cd ../app
terraform init
terraform apply

# From here on, changing chart/ and pushing to main is enough -- ArgoCD's
# own sync loop picks it up. No Terraform involvement, no re-apply needed.

# Optional: point your own kubectl/helm at the cluster too
$(terraform -chdir=../platform output -raw get_credentials_command)
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Teardown, in order:

```bash
cd v2-argocd/app && terraform destroy       # removes just the Application; ArgoCD prunes the workload under it
cd ../platform && terraform destroy         # removes everything, including ArgoCD and AKS
```

## Live results (confirmed on a real apply)

This version has been applied live end to end: AKS cluster up, ArgoCD
installed, the app deployed through a real ArgoCD `Application` (GitOps
sync from this repo, not `kubectl apply` on the Deployment directly),
reporting **Synced / Healthy**. The Redis connection string was confirmed
present as an env var inside the running container (checked via a presence
count, not by printing the secret value). Torn down with `terraform
destroy` immediately after confirming -- 16 resources destroyed, nothing
left running.

That run predates the `platform/`/`app/` split above -- it used a single
Terraform root with ArgoCD installed by hand, the way this README described
it at the time. The infrastructure and Helm chart are otherwise unchanged;
only how the code is organized and how ArgoCD gets installed changed.

## Known gotchas

- **`kubernetes_manifest` needs a live, reachable cluster at plan time, not
  just apply time** -- `app/`'s `terraform plan` will fail outright if
  `platform/`'s cluster has been destroyed or is unreachable. This is by
  design (see "Why splitting the Application into its own root is safe"
  above), not a bug to work around.
- **`terraform_remote_state` with a `local` backend reads a file path, not
  a live API** -- `app/` literally opens `../platform/terraform.tfstate`.
  If `platform/`'s state file has moved, been deleted, or was never
  applied, `app/`'s very first `terraform plan` fails immediately with a
  clear "no state file" error rather than something more cryptic.
- **`Standard_B2s` is blocked by an allowed-VM-SKU policy on this
  subscription** -- a *different* restriction from vCPU quota (which this
  subscription does have, post-upgrade). The cluster creation error names
  the exact allowed list; `Standard_D2s_v3` (same 2 vCPU / 8 GiB shape) is
  on it and is what `platform/variables.tf` defaults to now.
- **AKS's default Kubernetes service CIDR collides with this version's own
  VNet**: AKS defaults `network_profile.service_cidr` to `10.0.0.0/16` when
  unset, which overlaps this version's own `10.0.0.0/16` VNet (added for
  the Redis private endpoint). Fixed by pinning `service_cidr =
  "10.100.0.0/16"` and `dns_service_ip = "10.100.0.10"` explicitly.
- **Containers sharing a network namespace**: a pod's containers share
  networking, same as containers in a single Container App revision (v1).
  Both containers defaulting to `nginx:latest` would both try to bind `:80`
  and one would crash-loop -- the `sidecar` container in
  [chart/templates/deployment.yaml](chart/templates/deployment.yaml)
  overrides its command to `["sleep", "infinity"]` to avoid this.
- **Key Vault name collisions**: vault names are globally unique across
  every Azure tenant. The name includes a random 4-character suffix
  (`random_string.kv_suffix`), which also means it **can't be hardcoded**
  in `chart/values.yaml` -- it flows from `platform/`'s outputs into
  `app/`'s Application resource instead.
- **RBAC propagation delay**: same risk as v1 -- a fresh `platform/ apply`
  can occasionally 403 on the first secret write even with `depends_on`
  ordering the API calls correctly, since the role assignment itself can
  take a minute or two to propagate. A second `apply` fixes it.
- **Rotation only reaches the mounted file and the Secret object, not a
  running pod's environment**: `secret_rotation_enabled = true` makes the
  CSI driver periodically re-pull from Key Vault and update the mounted
  file *and* the synced `app-secrets` Kubernetes Secret. But this Deployment
  reads secrets via `secretKeyRef` into an env var, and **env vars are only
  read once, at container start** -- a pod has to actually restart to pick
  up a rotated value. (The mounted file at `/mnt/secrets-store` *does*
  update live, which is why some workloads read secrets from the file
  directly instead of an env var, specifically to get live rotation without
  a restart.)

## Cost notes

`platform/` has an **always-on cost** while it exists (the AKS node VM
bills per hour regardless of use, even though the control plane itself is
free on the `Free` SKU tier; Redis adds its own always-on cost on top, no
free tier at all, Basic C0 is about $0.02/hour). `app/` has effectively
**zero marginal cost** -- it's a single Kubernetes custom resource, not a
billed Azure resource. That asymmetry is the point of the split: iterate on
`app/`/`chart/` as often as you like without it costing anything extra;
the only thing actually burning money by the hour is `platform/`, so that's
the one to consciously apply-once-and-destroy-when-done rather than
recreate on every iteration.

## How this compares to v1

| | v1 (Container Apps) | v2 (this version) |
|---|---|---|
| Compute | Serverless, consumption-billed | AKS node pool, billed whether idle or not |
| Delivery | `terraform apply` deploys the app directly | ArgoCD reconciles a Helm chart from git -- Terraform never touches the running app |
| Secrets | Key Vault → container app via `key_vault_secret_id` | Key Vault → Kubernetes `Secret` via the CSI driver's `SecretProviderClass` |
| Drift correction | None built in | Automatic -- ArgoCD's `selfHeal` reverts manual changes |
| Operational overhead | Near zero | A cluster to patch, upgrade, and pay for |
| Redis reachability | Container Apps environment VNet-integrated at creation | AKS cluster's own VNet integration (`network_plugin = "azure"`) |
| Redeploy cost | Full `terraform apply`/`destroy` cycle every time | `platform/` applied once and left running; `app/`/`chart/` redeploy freely on top, no marginal cost |
