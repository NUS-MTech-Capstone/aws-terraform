data "aws_route53_zone" "application" {
  name         = var.route53_zone_name
  private_zone = false
}

resource "aws_acm_certificate" "application" {
  domain_name       = var.application_domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Environment = var.env
    Project     = var.name
  }
}

resource "aws_route53_record" "application_certificate_validation" {
  for_each = {
    for option in aws_acm_certificate.application.domain_validation_options :
    option.domain_name => {
      name   = option.resource_record_name
      record = option.resource_record_value
      type   = option.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.application.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "application" {
  certificate_arn = aws_acm_certificate.application.arn
  validation_record_fqdns = [
    for record in aws_route53_record.application_certificate_validation : record.fqdn
  ]
}

data "aws_lb" "application" {
  count = var.application_alb_dns_name == "" ? 0 : 1
  name  = var.application_alb_name
}

resource "aws_route53_record" "application" {
  count = var.application_alb_dns_name == "" ? 0 : 1

  zone_id = data.aws_route53_zone.application.zone_id
  name    = var.application_domain_name
  type    = "A"

  alias {
    name                   = data.aws_lb.application[0].dns_name
    zone_id                = data.aws_lb.application[0].zone_id
    evaluate_target_health = true
  }

  lifecycle {
    precondition {
      condition     = data.aws_lb.application[0].dns_name == var.application_alb_dns_name
      error_message = "application_alb_dns_name does not match the ALB named by application_alb_name."
    }
  }
}

output "application_certificate_arn" {
  value = aws_acm_certificate_validation.application.certificate_arn
}

output "application_domain_name" {
  value = var.application_domain_name
}
