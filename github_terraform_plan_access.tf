# Terraform refresh reads managed secret versions and Helm release metadata.
# This role cannot apply changes, modify state, execute commands or mutate workloads.
resource "aws_iam_role_policy" "github_terraform_plan_secrets" {
  name = "terraform-managed-secret-refresh"
  role = aws_iam_role.github_terraform_plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue"]
      Resource = [
        aws_secretsmanager_secret.webapp_database_url.arn,
        aws_secretsmanager_secret.webapp_database_bootstrap.arn,
        aws_secretsmanager_secret.incident_database_url.arn,
        aws_secretsmanager_secret.incident_agent_langsmith_api_key.arn,
      ]
    }]
  })
}

resource "aws_eks_access_entry" "github_terraform_plan" {
  cluster_name      = module.eks.cluster_name
  principal_arn     = aws_iam_role.github_terraform_plan.arn
  kubernetes_groups = ["dendenmushi:terraform-plan"]
  type              = "STANDARD"
}

resource "kubernetes_cluster_role" "github_terraform_plan" {
  metadata {
    name = "dendenmushi-terraform-plan"
  }
  rule {
    api_groups     = [""]
    resources      = ["namespaces"]
    resource_names = ["argocd", "cert-manager", "kube-system", "dendenmushi-ssh", "dendenmushi-agentic", "dendenmushi-webapp"]
    verbs          = ["get"]
  }
  rule {
    api_groups     = [""]
    resources      = ["serviceaccounts"]
    resource_names = ["aws-load-balancer-controller"]
    verbs          = ["get"]
  }
  rule {
    api_groups     = ["rbac.authorization.k8s.io"]
    resources      = ["roles", "rolebindings"]
    resource_names = ["database-shell", "argocd-server-port-forward", "terraform-plan-helm"]
    verbs          = ["get"]
  }
  rule {
    api_groups     = ["rbac.authorization.k8s.io"]
    resources      = ["clusterroles", "clusterrolebindings"]
    resource_names = ["dendenmushi-terraform-plan"]
    verbs          = ["get"]
  }
}

resource "kubernetes_cluster_role_binding" "github_terraform_plan" {
  metadata {
    name = "dendenmushi-terraform-plan"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.github_terraform_plan.metadata[0].name
  }
  subject {
    kind      = "Group"
    name      = "dendenmushi:terraform-plan"
    api_group = "rbac.authorization.k8s.io"
  }
}

resource "kubernetes_role" "github_terraform_plan_helm" {
  for_each = toset(["argocd", "cert-manager", "kube-system"])
  metadata {
    name      = "terraform-plan-helm"
    namespace = each.key
  }
  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_role_binding" "github_terraform_plan_helm" {
  for_each = kubernetes_role.github_terraform_plan_helm
  metadata {
    name      = "terraform-plan-helm"
    namespace = each.key
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = each.value.metadata[0].name
  }
  subject {
    kind      = "Group"
    name      = "dendenmushi:terraform-plan"
    api_group = "rbac.authorization.k8s.io"
  }
}
