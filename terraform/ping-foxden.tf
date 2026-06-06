resource "aws_s3_bucket" "ping" {
  region = "eu-north-1"
  bucket = "ping-foxden"
}

resource "aws_s3_bucket_ownership_controls" "ping" {
  region = "eu-north-1"
  bucket = aws_s3_bucket.ping.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

data "aws_iam_policy_document" "ping" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.ping.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.ping.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "ping" {
  region = "eu-north-1"
  bucket = aws_s3_bucket.ping.id

  policy = data.aws_iam_policy_document.ping.json
}

resource "aws_acm_certificate" "ping" {
  region            = "us-east-1"
  domain_name       = "ping.foxden.network"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "cloudns_dns_record" "ping_validation" {
  for_each = {
    for dvo in aws_acm_certificate.ping.domain_validation_options : "${dvo.resource_record_name}@${dvo.resource_record_type}" => {
      name  = dvo.resource_record_name
      value = dvo.resource_record_value
      type  = dvo.resource_record_type
    }
  }

  zone = "foxden.network"

  type  = each.value.type
  name  = trimsuffix(each.value.name, ".foxden.network.")
  ttl   = 3600
  value = trimsuffix(each.value.value, ".")
}

resource "aws_wafv2_web_acl" "ping" {
  region      = "us-east-1"
  name        = "foxden-ping-web-acl"
  description = "Web ACL for the FoxDen ping service"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  visibility_config {
    cloudwatch_metrics_enabled = false
    metric_name                = "unused-metric"
    sampled_requests_enabled   = false
  }
}

resource "aws_cloudfront_origin_access_control" "ping" {
  name                              = "ping-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "ping" {
  origin {
    domain_name              = aws_s3_bucket.ping.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.ping.id
    origin_id                = "ping_s3_origin_id"
  }

  enabled         = true
  is_ipv6_enabled = true
  http_version    = "http2and3"
  aliases         = [aws_acm_certificate.ping.domain_name]
  web_acl_id      = aws_wafv2_web_acl.ping.arn

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "ping_s3_origin_id"
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
    viewer_protocol_policy = "allow-all"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    ssl_support_method       = "sni-only"
    acm_certificate_arn      = aws_acm_certificate.ping.arn
    minimum_protocol_version = "TLSv1"
  }
}

resource "cloudns_dns_record" "ping_cname" {
  zone = "foxden.network"

  type  = "CNAME"
  name  = "ping"
  ttl   = 3600
  value = aws_cloudfront_distribution.ping.domain_name
}

output "generated_records" {
  value = {
    "foxden.network" = [for r in setunion(values(cloudns_dns_record.ping_validation), [cloudns_dns_record.ping_cname]) : {
      type     = upper(r.type)
      fqdn     = r.name == "@" ? r.zone : "${r.name}.${r.zone}"
      name     = r.name
      ttl      = r.ttl
      value    = r.value
      critical = false
      horizon  = "*"
    }]
  }
}
