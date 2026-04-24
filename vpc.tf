variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  description = "List of availability zones to use for subnets"
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b"]
}

locals {
  public_a_cidr = cidrsubnet(var.vpc_cidr, 8, 0)  # → public_subnets[0]
  public_b_cidr = cidrsubnet(var.vpc_cidr, 8, 1)  # → public_subnets[1]
  app_a_cidr    = cidrsubnet(var.vpc_cidr, 8, 10) # → private_subnets[0]
  app_b_cidr    = cidrsubnet(var.vpc_cidr, 8, 11) # → private_subnets[1]
  db_a_cidr     = cidrsubnet(var.vpc_cidr, 8, 20) # → database_subnets[0]
  db_b_cidr     = cidrsubnet(var.vpc_cidr, 8, 21) # → database_subnets[1]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.21"

  name = "${var.name}-vpc-${var.env}"
  cidr = var.vpc_cidr

  # Availability Zones
  azs = var.azs

  # Subnets (order matters)
  public_subnets = [
    local.public_a_cidr,
    local.public_b_cidr
  ]

  private_subnets = [
    local.app_a_cidr,
    local.app_b_cidr,

  ]

  database_subnets = [
    local.db_a_cidr,
    local.db_b_cidr
  ]

  create_database_subnet_group = true

  # NAT Gateway 
  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false # false for single NAT

  tags = {
    Environment = var.env
    Project     = var.name
  }

  # Subnet-specific tags for EKS
  public_subnet_tags = {
    "kubernetes.io/cluster/${var.name}-cluster-${var.env}" = "shared"
    "kubernetes.io/role/elb"                               = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.name}-cluster-${var.env}" = "shared"
    "kubernetes.io/role/internal-elb"                      = "1"
  }

  database_subnet_tags = {
    "kubernetes.io/cluster/${var.name}-cluster-${var.env}" = "shared"
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id       = module.vpc.vpc_id
  service_name = "com.amazonaws.${var.aws_region}.s3"

  route_table_ids = distinct(concat(
    module.vpc.private_route_table_ids,
    module.vpc.database_route_table_ids
  ))

  tags = {
    Name        = "${var.name}-s3-endpoint-${var.env}"
    Environment = var.env
    Project     = var.name
  }
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  value = module.vpc.vpc_cidr_block
}

output "public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "database_subnet_ids" {
  value = module.vpc.database_subnets
}

output "database_subnet_group_name" {
  value = module.vpc.database_subnet_group_name
}

output "nat_public_ips" {
  value = module.vpc.nat_public_ips
}

output "vpc_endpoint_s3_id" {
  description = "ID of S3 VPC endpoint"
  value       = aws_vpc_endpoint.s3.id
}

# For EKS-specific subnet groups
output "eks_public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "eks_private_subnet_ids" {
  value = module.vpc.private_subnets
}
