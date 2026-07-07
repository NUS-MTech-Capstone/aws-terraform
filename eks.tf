data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

variable "eks_managed_node_desired_size" {
  description = "Desired size of the EKS managed node group"
  type        = number
  default     = 3
}

variable "eks_managed_node_min_size" {
  description = "Minimum size of the EKS managed node group"
  type        = number
  default     = 3
}

variable "eks_managed_node_max_size" {
  description = "Maximum size of the EKS managed node group"
  type        = number
  default     = 3
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.23.0"

  name               = "${var.name}-cluster-${var.env}"
  kubernetes_version = "1.35"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access = true

  access_entries = {
    for key, principal_arn in local.teammate_access_eks_principal_arn_map : key => {
      principal_arn     = principal_arn
      kubernetes_groups = local.teammate_access_kubernetes_groups

      policy_associations = {
        readonly = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  enabled_log_types                      = ["api", "audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = 1

  eks_managed_node_groups = {
    default = {
      name = "${var.name}-ng-${var.env}"

      instance_types = ["t3.medium"]
      desired_size   = var.eks_managed_node_desired_size
      min_size       = var.eks_managed_node_min_size
      max_size       = var.eks_managed_node_max_size

      capacity_type = "ON_DEMAND"

      bootstrap_extra_args = "--kubelet-extra-args '--node-labels=node-group=default'"

      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore       = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
        AmazonEKSWorkerNodePolicy          = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
        AmazonEKS_CNI_Policy               = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
        AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
      }
    }
  }

  # Allow communication between nodes and cluster
  security_group_additional_rules = {
    ingress_nodes_ephemeral_ports_tcp = {
      description                = "Nodes on ephemeral ports"
      protocol                   = "tcp"
      from_port                  = 1025
      to_port                    = 65535
      type                       = "ingress"
      source_node_security_group = true
    }
  }

  # Node group security group rules
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    ingress_cluster_to_node_all = {
      description                   = "Cluster API to node"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }


  tags = {
    Environment = var.env
    Project     = var.name
  }
}

locals {
  container_insights_log_groups = toset([
    "/aws/containerinsights/${module.eks.cluster_name}/application",
    "/aws/containerinsights/${module.eks.cluster_name}/dataplane",
    "/aws/containerinsights/${module.eks.cluster_name}/host",
    "/aws/containerinsights/${module.eks.cluster_name}/performance",
    "/aws/containerinsights/${module.eks.cluster_name}/prometheus",
  ])
}

resource "aws_cloudwatch_log_group" "container_insights" {
  for_each = local.container_insights_log_groups

  name              = each.value
  retention_in_days = 1

  tags = {
    Environment = var.env
    Project     = var.name
    Retention   = "1-day-school-project"
  }
}

resource "aws_iam_role" "cloudwatch_observability_addon" {
  name = "${var.name}-${var.env}-cloudwatch-observability-addon"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession",
        ]
      }
    ]
  })

  tags = {
    Environment = var.env
    Project     = var.name
  }
}

resource "aws_iam_role_policy_attachment" "cloudwatch_observability_addon" {
  role       = aws_iam_role.cloudwatch_observability_addon.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_pod_identity_association" "cloudwatch_agent" {
  cluster_name    = module.eks.cluster_name
  namespace       = "amazon-cloudwatch"
  service_account = "cloudwatch-agent"
  role_arn        = aws_iam_role.cloudwatch_observability_addon.arn

  depends_on = [aws_eks_addon.pod_identity_agent]
}

resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "amazon-cloudwatch-observability"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_cloudwatch_log_group.container_insights,
    aws_eks_pod_identity_association.cloudwatch_agent,
    aws_iam_role_policy_attachment.cloudwatch_observability_addon,
  ]
}

resource "local_file" "kubeconfig" {
  depends_on = [module.eks]

  content = templatefile("${path.module}/kubeconfig.tpl", {
    cluster_name = module.eks.cluster_name
    endpoint     = module.eks.cluster_endpoint
    ca_data      = module.eks.cluster_certificate_authority_data
  })

  filename = "${path.module}/kubeconfig_${var.env}"
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_security_group_id" {
  description = "Security group ID attached to EKS cluster"
  value       = module.eks.cluster_security_group_id
}

output "eks_node_security_group_id" {
  description = "Security group attached to EKS worker nodes"
  value       = module.eks.node_security_group_id
}

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

output "node_group_name" {
  description = "EKS managed node group name"
  value       = split(":", module.eks.eks_managed_node_groups["default"].node_group_id)[1]
}
