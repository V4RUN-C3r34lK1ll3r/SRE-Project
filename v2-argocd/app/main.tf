### Reads ../platform/'s state -- cluster + Key Vault + ArgoCD already
# exist by the time this root is ever applied. This is a genuinely
# separate `terraform apply` invocation from platform/'s, run strictly
# afterwards, which is what makes managing the Application CRD instance
# here safe: `kubernetes_manifest` does a schema-validated dry run
# against the live cluster at plan time, so the CRD it targets (ArgoCD's
# own Application CRD, installed by platform/'s helm_release) has to
# already exist. Installing ArgoCD and defining an Application for it in
# the *same* apply would be a chicken-and-egg problem; two separate
# roots, always applied in order, sidesteps it structurally.

data "terraform_remote_state" "platform" {
  backend = "local"

  config = {
    path = "${path.module}/../platform/terraform.tfstate"
  }
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.platform.outputs.kube_config_host
  client_certificate     = base64decode(data.terraform_remote_state.platform.outputs.kube_config_client_certificate)
  client_key             = base64decode(data.terraform_remote_state.platform.outputs.kube_config_client_key)
  cluster_ca_certificate = base64decode(data.terraform_remote_state.platform.outputs.kube_config_cluster_ca_certificate)
}

### The ArgoCD Application -- this is the *only* thing this root manages.
# Everything it points at (the Deployment, Service, SecretProviderClass in
# ../chart/) is synced and owned by ArgoCD itself, never by Terraform.
# `terraform destroy` here removes only this pointer -- ArgoCD prunes the
# workload underneath it -- without touching the cluster or ArgoCD's own
# install in ../platform/.

resource "kubernetes_manifest" "argocd_application" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "sre-takehome-app"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = "https://github.com/V4RUN-C3r34lK1ll3r/SRE-Project.git"
        targetRevision = "main"
        path           = "v2-argocd/chart"
        helm = {
          parameters = [
            {
              name  = "keyVault.userAssignedIdentityID"
              value = data.terraform_remote_state.platform.outputs.key_vault_secrets_provider_client_id
            },
            {
              name  = "keyVault.name"
              value = data.terraform_remote_state.platform.outputs.key_vault_name
            },
            {
              name  = "keyVault.tenantId"
              value = data.terraform_remote_state.platform.outputs.tenant_id
            },
          ]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "default"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  }
}
