variable "env" {
  description = "dev, staging, prod"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  type    = string
  default = "ap-southeast-1" # sg 
}

variable "name" {
  type    = string
  default = "dendenmushi"
}

variable "domain_name" {
  type    = string
  default = "ddm.keiyam.me"
}

variable "origin_domain_name" {
  type    = string
  default = "origin.ddm.keiyam.me"
}

variable "aws_iam_access_key_id" {
  type      = string
  sensitive = true
}

variable "aws_iam_access_key_secret" {
  type      = string
  sensitive = true
}

variable "postgres_db_name" {
  type    = string
  default = "dendenmushi"
}

variable "postgres_db_username" {
  type    = string
  default = "dendenmushi"
}

variable "postgres_db_password" {
  type      = string
  sensitive = true
}

variable "postgres_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "static_files_force_destroy" {
  description = "Allow Terraform destroy to remove the static files bucket even when it contains objects. Keep true for dev/capstone environments."
  type        = bool
  default     = true
}
