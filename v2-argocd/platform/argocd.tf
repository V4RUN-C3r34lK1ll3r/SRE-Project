### ArgoCD itself -- platform tooling, not app-layer #################
# This is the one thing that used to be a manual `helm install` command
# a human had to remember to run after `terraform apply`. Managing it
# here instead means the platform layer -- cluster + the GitOps
# controller that watches it -- is one idempotent, drift-checked apply.
# It's still deliberately kept separate from the *app* layer: this
# resource only ever installs ArgoCD itself, never the Application CRD
# instance that points ArgoCD at this repo's chart (see ../app/) -- so
# app-layer teardown/redeploy never touches this resource or the
# cluster it runs on.

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 300

  depends_on = [azurerm_kubernetes_cluster.this]
}
