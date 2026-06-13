
variable "cognito_callback_urls" {
  type    = list(string)
  default = ["https://api.ddm.keiyam.me/oauth2/idpresponse"]
}

variable "cognito_logout_urls" {
  type    = list(string)
  default = ["https://api.ddm.keiyam.me/logout"]
}

variable "cognito_domain_prefix" {
  type    = string
  default = "ddm-keiyam-dev"
}
