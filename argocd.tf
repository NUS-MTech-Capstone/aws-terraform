variable "argocd_chart_version" {
  description = "Pinned upstream Argo CD Helm chart version."
  type        = string
  default     = "9.1.4"
}

variable "argocd_readonly_accounts" {
  description = "Local Argo CD accounts with readonly access. Passwords are set out of band with the Argo CD CLI."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for account in var.argocd_readonly_accounts :
      can(regex("^[a-zA-Z0-9._-]+$", account))
    ])
    error_message = "Argo CD readonly account names may contain only letters, numbers, dot, underscore, and hyphen."
  }
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
        cm = merge(
          {
            "admin.enabled" = true
          },
          {
            for account in var.argocd_readonly_accounts :
            "accounts.${account}" => "login"
          },
          {
            for account in var.argocd_readonly_accounts :
            "accounts.${account}.enabled" => "true"
          },
        )
        params = {
          "server.insecure" = false
        }
        rbac = {
          "policy.default" = "role:readonly"
          "policy.csv" = join("\n", [
            for account in sort(tolist(var.argocd_readonly_accounts)) :
            "g, ${account}, role:readonly"
          ])
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
