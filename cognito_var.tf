
variable "cognito_callback_urls" {
  type    = list(string)
  default = ["https://api.ddm.keiyam.me/oauth2/idpresponse"]
}

variable "cognito_logout_urls" {
  type    = list(string)
  default = ["https://api.ddm.keiyam.me/login"]
}

variable "cognito_domain_prefix" {
  type    = string
  default = "ddm-keiyam-dev"
}

variable "cognito_admin_username" {
  description = "Deprecated. Create/add the initial webapp Admin user with AWS CLI before deployment."
  type        = string
  default     = ""
}
