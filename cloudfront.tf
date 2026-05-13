resource "time_sleep" "wait_for_ok_alb" {
  create_duration = "300s"

  depends_on = [kubernetes_ingress_v1.ok]
}

data "aws_lb" "ok_ingress" {
  name = local.test_alb_name

  depends_on = [time_sleep.wait_for_ok_alb]
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

resource "aws_cloudfront_distribution" "ok" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${var.name} ${var.env} test endpoint"
  aliases         = [var.domain_name]
  price_class     = "PriceClass_100"

  origin {
    domain_name = data.aws_lb.ok_ingress.dns_name
    origin_id   = "ok-alb"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "ok-alb"
    viewer_protocol_policy = "redirect-to-https"
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_disabled.id
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cf.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  depends_on = [aws_acm_certificate_validation.cf]
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.ok.id
}

output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.ok.domain_name
}

output "cloudfront_hosted_zone_id" {
  value = aws_cloudfront_distribution.ok.hosted_zone_id
}

output "manual_route53_record" {
  value = {
    name  = var.domain_name
    type  = "A/AAAA alias or CNAME"
    value = aws_cloudfront_distribution.ok.domain_name
  }
}

output "test_alb_dns_name" {
  value = data.aws_lb.ok_ingress.dns_name
}
