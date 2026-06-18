variable "argocd_chart_version" {
  description = "Pinned upstream Argo CD Helm chart version."
  type        = string
  default     = "9.1.4"
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"

    labels = {
      "app.kubernetes.io/name"       = "argocd"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  timeout    = 1800

  values = [
    yamlencode({
      configs = {
        params = {
          "server.insecure" = false
        }
      }
      server = {
        service = {
          type = "ClusterIP"
        }
      }
    })
  ]

  depends_on = [module.eks]
}

output "argocd_namespace" {
  description = "Namespace where Argo CD is installed."
  value       = kubernetes_namespace.argocd.metadata[0].name
}
