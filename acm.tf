resource "aws_acm_certificate" "cf" {
  provider          = aws.use1
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

output "cf_certificate_arn" {
  value = aws_acm_certificate.cf.arn
}

output "cf_validation_records" {
  value = [
    for dvo in aws_acm_certificate.cf.domain_validation_options : {
      domain_name = dvo.domain_name
      name        = dvo.resource_record_name
      type        = dvo.resource_record_type
      value       = dvo.resource_record_value
    }
  ]
}

resource "aws_acm_certificate_validation" "cf" {
  provider        = aws.use1
  certificate_arn = aws_acm_certificate.cf.arn
  validation_record_fqdns = [
    for dvo in aws_acm_certificate.cf.domain_validation_options : dvo.resource_record_name
  ]
}
