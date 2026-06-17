data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

variable "eks_managed_node_desired_size" {
  description = "Desired size of the EKS managed node group"
  type        = number
  default     = 1
}

variable "eks_managed_node_min_size" {
  description = "Minimum size of the EKS managed node group"
  type        = number
  default     = 1
}

variable "eks_managed_node_max_size" {
  description = "Maximum size of the EKS managed node group"
  type        = number
  default     = 1
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.23.0"

  name               = "${var.name}-cluster-${var.env}"
  kubernetes_version = "1.35"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access = true

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
