resource "aws_iam_policy" "proxy_dataplane_secrets" {
  name        = "${var.name}-proxy-dataplane-secrets-${var.env}"
  description = "Allow proxy dataplane pods to retrieve target SSH private keys"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:dendenmushi/targets/*"
    }]
  })
}

module "iam_assumable_role_proxy_dataplane" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "5.39.0"

  create_role                   = true
  role_name                     = "${var.name}-proxy-dataplane-${var.env}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [aws_iam_policy.proxy_dataplane_secrets.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:dendenmushi:proxy-dataplane"]
}

output "proxy_dataplane_role_arn" {
  value = module.iam_assumable_role_proxy_dataplane.iam_role_arn
}

