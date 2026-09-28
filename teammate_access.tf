variable "teammate_access_user_names" {
  description = "IAM usernames to create for teammate access. Leave empty to avoid managing IAM users."
  type        = set(string)
  default     = []
}

variable "teammate_access_existing_user_names" {
  description = "Existing IAM usernames to add to the teammate access group without creating them."
  type        = set(string)
  default     = []
}

variable "teammate_access_principal_arns" {
  description = "Existing IAM user or role ARNs that should receive readonly EKS kubectl access."
  type        = set(string)
  default     = []
}

variable "teammate_access_full_s3_admin" {
  description = "Grant AmazonS3FullAccess instead of admin access only to the project static-files bucket."
  type        = bool
  default     = false
}

variable "teammate_access_database_shell" {
  description = "Allow teammate IAM users to read project database connection secrets and create temporary database client pods in the SSH and webapp namespaces."
  type        = bool
  default     = false
}

variable "teammate_access_argocd_port_forward" {
  description = "Allow teammate IAM users to port-forward the Argo CD server service in the argocd namespace."
  type        = bool
  default     = false
}

variable "teammate_access_extra_policy_names" {
  description = "Additional customer-managed IAM policy names in this account to attach to the teammate access group."
  type        = set(string)
  default     = []
}

variable "teammate_access_extra_aws_managed_policy_names" {
  description = "Additional AWS managed IAM policy names to attach to the teammate access group."
  type        = set(string)
  default     = []
}

variable "teammate_access_extra_policy_arns" {
  description = "Additional IAM policy ARNs to attach to the teammate access group."
  type        = set(string)
  default     = []
}

locals {
  teammate_access_group_user_names = setunion(
    var.teammate_access_user_names,
    var.teammate_access_existing_user_names,
  )

  teammate_access_created_user_arns = toset([
    for user in aws_iam_user.teammate_access : user.arn
  ])

  teammate_access_existing_user_arns = toset([
    for user in data.aws_iam_user.teammate_access_existing : user.arn
  ])

  teammate_access_eks_principal_arn_map = merge(
    {
      for user_name in var.teammate_access_user_names :
      "created_user_${user_name}" => aws_iam_user.teammate_access[user_name].arn
    },
    {
      for user_name in var.teammate_access_existing_user_names :
      "existing_user_${user_name}" => data.aws_iam_user.teammate_access_existing[user_name].arn
    },
    {
      for arn in var.teammate_access_principal_arns :
      "principal_${substr(md5(arn), 0, 12)}" => arn
    },
  )

  teammate_access_extra_policy_arns = setunion(
    var.teammate_access_extra_policy_arns,
    toset([
      for name in var.teammate_access_extra_policy_names :
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${name}"
    ]),
    toset([
      for name in var.teammate_access_extra_aws_managed_policy_names :
      "arn:aws:iam::aws:policy/${name}"
    ]),
  )

  teammate_access_kubernetes_groups = concat(
    var.teammate_access_database_shell ? ["dendenmushi:database-shell"] : [],
    var.teammate_access_argocd_port_forward ? ["argocd:port-forward"] : [],
  )
}

data "aws_iam_user" "teammate_access_existing" {
  for_each = var.teammate_access_existing_user_names

  user_name = each.value
}

resource "aws_iam_user" "teammate_access" {
  for_each = var.teammate_access_user_names

  name = each.value
  path = "/users/"

  tags = {
    Environment = var.env
    Project     = var.name
    AccessScope = "teammate"
  }
}

resource "aws_iam_group" "teammate_access" {
  count = length(local.teammate_access_group_user_names) > 0 ? 1 : 0

  name = "${var.name}-${var.env}-teammate-access"
  path = "/groups/"
}

resource "aws_iam_user_group_membership" "teammate_access" {
  for_each = local.teammate_access_group_user_names

  user = each.value

  groups = [
    aws_iam_group.teammate_access[0].name,
  ]
}

resource "aws_iam_policy" "teammate_access_infrastructure_readonly" {
  count = length(local.teammate_access_group_user_names) > 0 ? 1 : 0

  name        = "${var.name}-${var.env}-teammate-infrastructure-readonly"
  description = "Teammate readonly access for DenDenMushi AWS infrastructure diagnostics."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InfrastructureReadOnly"
        Effect = "Allow"
        Action = [
          "acm:Describe*",
          "acm:Get*",
          "acm:List*",
          "autoscaling:Describe*",
          "cloudwatch:Describe*",
          "cloudwatch:Get*",
          "cloudwatch:List*",
          "ec2:Describe*",
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:Describe*",
          "ecr:GetAuthorizationToken",
          "ecr:GetDownloadUrlForLayer",
          "ecr:List*",
          "eks:AccessKubernetesApi",
          "eks:Describe*",
          "eks:List*",
          "elasticloadbalancing:Describe*",
          "iam:Get*",
          "iam:List*",
          "logs:Describe*",
          "logs:FilterLogEvents",
          "logs:Get*",
          "logs:List*",
          "logs:StartQuery",
          "logs:StopQuery",
          "rds:Describe*",
          "rds:List*",
          "route53:Get*",
          "route53:List*",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecrets",
          "sts:GetCallerIdentity",
          "tag:GetResources",
          "tag:GetTagKeys",
          "tag:GetTagValues",
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Environment = var.env
    Project     = var.name
  }
}

resource "aws_iam_group_policy_attachment" "teammate_access_infrastructure_readonly" {
  count = length(local.teammate_access_group_user_names) > 0 ? 1 : 0

  group      = aws_iam_group.teammate_access[0].name
  policy_arn = aws_iam_policy.teammate_access_infrastructure_readonly[0].arn
}

resource "aws_iam_group_policy_attachment" "teammate_access_change_password" {
  count = length(local.teammate_access_group_user_names) > 0 ? 1 : 0

  group      = aws_iam_group.teammate_access[0].name
  policy_arn = "arn:aws:iam::aws:policy/IAMUserChangePassword"
}

resource "aws_iam_policy" "teammate_access_cli_self_service" {
  count = length(local.teammate_access_group_user_names) > 0 ? 1 : 0

  name        = "${var.name}-${var.env}-teammate-cli-self-service"
  description = "Teammate self-service IAM permissions for AWS CLI access keys and MFA."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageOwnAccessKeys"
        Effect = "Allow"
        Action = [
          "iam:CreateAccessKey",
          "iam:DeleteAccessKey",
          "iam:GetUser",
          "iam:ListAccessKeys",
          "iam:UpdateAccessKey",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/$${aws:username}"
      },
      {
        Sid    = "ManageOwnVirtualMFADevice"
        Effect = "Allow"
        Action = [
          "iam:CreateVirtualMFADevice",
          "iam:DeleteVirtualMFADevice",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:mfa/$${aws:username}"
      },
      {
        Sid    = "ManageOwnMFAAssignment"
        Effect = "Allow"
        Action = [
          "iam:DeactivateMFADevice",
          "iam:EnableMFADevice",
          "iam:ListMFADevices",
          "iam:ResyncMFADevice",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/$${aws:username}"
      },
      {
        Sid    = "ListAccountMFAAndAccessKeyMetadataForConsole"
        Effect = "Allow"
        Action = [
          "iam:GetAccessKeyLastUsed",
          "iam:ListVirtualMFADevices",
        ]
        Resource = "*"
      },
    ]
  })

  tags = {
    Environment = var.env
    Project     = var.name
  }
}

resource "aws_iam_group_policy_attachment" "teammate_access_cli_self_service" {
  count = length(local.teammate_access_group_user_names) > 0 ? 1 : 0

  group      = aws_iam_group.teammate_access[0].name
  policy_arn = aws_iam_policy.teammate_access_cli_self_service[0].arn
}

resource "aws_iam_group_policy_attachment" "teammate_access_cloudshell" {
  count = length(local.teammate_access_group_user_names) > 0 ? 1 : 0

  group      = aws_iam_group.teammate_access[0].name
  policy_arn = "arn:aws:iam::aws:policy/AWSCloudShellFullAccess"
}

resource "aws_iam_group_policy_attachment" "teammate_access_extra" {
  for_each = length(local.teammate_access_group_user_names) > 0 ? local.teammate_access_extra_policy_arns : toset([])

  group      = aws_iam_group.teammate_access[0].name
  policy_arn = each.value
}

resource "aws_iam_group_policy_attachment" "teammate_access_full_s3_admin" {
  count = length(local.teammate_access_group_user_names) > 0 && var.teammate_access_full_s3_admin ? 1 : 0

  group      = aws_iam_group.teammate_access[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_policy" "teammate_access_project_admin" {
  count = length(local.teammate_access_group_user_names) > 0 ? 1 : 0

  name        = "${var.name}-${var.env}-teammate-project-admin"
  description = "Teammate admin access for DenDenMushi Cognito and project S3 assets."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CognitoUserPoolAdmin"
        Effect = "Allow"
        Action = [
          "cognito-idp:*",
        ]
        Resource = aws_cognito_user_pool.this.arn
      },
      {
        Sid    = "CognitoConsoleRead"
        Effect = "Allow"
        Action = [
          "cognito-identity:*",
          "cognito-idp:DescribeUserPool",
          "cognito-idp:ListUserPools",
        ]
        Resource = "*"
      },
      {
        Sid    = "BucketDiscovery"
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:ListAllMyBuckets",
        ]
        Resource = "*"
      },
      {
        Sid    = "ProjectBucketList"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
        ]
        Resource = aws_s3_bucket.static_files.arn
      },
      {
        Sid    = "ProjectBucketAdmin"
        Effect = "Allow"
        Action = [
          "s3:*",
        ]
        Resource = [
          aws_s3_bucket.static_files.arn,
          "${aws_s3_bucket.static_files.arn}/*",
        ]
      },
    ]
  })

  tags = {
    Environment = var.env
    Project     = var.name
  }
}

resource "aws_iam_group_policy_attachment" "teammate_access_project_admin" {
  count = length(local.teammate_access_group_user_names) > 0 ? 1 : 0

  group      = aws_iam_group.teammate_access[0].name
  policy_arn = aws_iam_policy.teammate_access_project_admin[0].arn
}

resource "aws_iam_policy" "teammate_access_database_shell" {
  count = length(local.teammate_access_group_user_names) > 0 && var.teammate_access_database_shell ? 1 : 0

  name        = "${var.name}-${var.env}-teammate-database-shell"
  description = "Teammate access to project database connection secrets for temporary psql pods."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadProjectDatabaseConnectionSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
        ]
        Resource = [
          aws_secretsmanager_secret.incident_database_url.arn,
          aws_secretsmanager_secret.webapp_database_url.arn,
        ]
      },
    ]
  })

  tags = {
    Environment = var.env
    Project     = var.name
  }
}

resource "aws_iam_group_policy_attachment" "teammate_access_database_shell" {
  count = length(local.teammate_access_group_user_names) > 0 && var.teammate_access_database_shell ? 1 : 0

  group      = aws_iam_group.teammate_access[0].name
  policy_arn = aws_iam_policy.teammate_access_database_shell[0].arn
}

resource "kubernetes_role" "teammate_access_database_shell" {
  for_each = length(local.teammate_access_eks_principal_arn_map) > 0 && var.teammate_access_database_shell ? toset([
    "dendenmushi-ssh",
    "dendenmushi-webapp",
  ]) : toset([])

  metadata {
    name      = "database-shell"
    namespace = kubernetes_namespace.dendenmushi[each.key].metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["create", "delete", "get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/attach"]
    verbs      = ["create", "get"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get"]
  }

  depends_on = [module.eks]
}

resource "kubernetes_role_binding" "teammate_access_database_shell" {
  for_each = length(local.teammate_access_eks_principal_arn_map) > 0 && var.teammate_access_database_shell ? toset([
    "dendenmushi-ssh",
    "dendenmushi-webapp",
  ]) : toset([])

  metadata {
    name      = "database-shell"
    namespace = kubernetes_namespace.dendenmushi[each.key].metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.teammate_access_database_shell[each.key].metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = "dendenmushi:database-shell"
    api_group = "rbac.authorization.k8s.io"
  }

  depends_on = [module.eks]
}

resource "kubernetes_role" "teammate_access_argocd_port_forward" {
  count = length(local.teammate_access_eks_principal_arn_map) > 0 && var.teammate_access_argocd_port_forward ? 1 : 0

  metadata {
    name      = "argocd-server-port-forward"
    namespace = kubernetes_namespace.argocd.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "services"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/portforward"]
    verbs      = ["create"]
  }

  depends_on = [
    module.eks,
    helm_release.argocd,
  ]
}

resource "kubernetes_role_binding" "teammate_access_argocd_port_forward" {
  count = length(local.teammate_access_eks_principal_arn_map) > 0 && var.teammate_access_argocd_port_forward ? 1 : 0

  metadata {
    name      = "argocd-server-port-forward"
    namespace = kubernetes_namespace.argocd.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.teammate_access_argocd_port_forward[0].metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = "argocd:port-forward"
    api_group = "rbac.authorization.k8s.io"
  }

  depends_on = [
    module.eks,
    helm_release.argocd,
  ]
}

output "teammate_access_iam_user_arns" {
  description = "IAM user ARNs created for teammate access."
  value       = [for user in aws_iam_user.teammate_access : user.arn]
}
