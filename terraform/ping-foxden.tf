resource "aws_cloudfront_origin_access_identity" "ping_oai" {

}

resource "aws_s3_bucket" "ping_bucket" {
  region = "eu-north-1"
  bucket = "ping-foxden"
}

resource "aws_s3_bucket_ownership_controls" "ping_bucket_ownwership_controls" {
  region = "eu-north-1"
  bucket = aws_s3_bucket.ping_bucket.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

data "aws_iam_policy_document" "ping_bucket_policy" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.ping_bucket.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.ping_oai.iam_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "ping_bucket_policy" {
  region = "eu-north-1"
  bucket = aws_s3_bucket.ping_bucket.id

  policy = data.aws_iam_policy_document.ping_bucket_policy.json
}

resource "aws_acm_certificate" "ping_certificate" {
  region            = "us-east-1"
  domain_name       = "ping.foxden.network"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "cloudns_dns_record" "ping_validation_record" {
  for_each = {
    for dvo in aws_acm_certificate.ping_certificate.domain_validation_options : "${dvo.resource_record_name}@${dvo.resource_record_type}" => {
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

resource "aws_wafv2_web_acl" "ping_web_acl" {
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

resource "aws_cloudfront_distribution" "ping_distribution" {
  origin {
    domain_name = aws_s3_bucket.ping_bucket.bucket_regional_domain_name
    origin_id   = "ping_s3_origin_id"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.ping_oai.cloudfront_access_identity_path
    }
  }

  enabled         = true
  is_ipv6_enabled = true
  aliases         = [aws_acm_certificate.ping_certificate.domain_name]
  web_acl_id      = aws_wafv2_web_acl.ping_web_acl.arn

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "ping_s3_origin_id"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    ssl_support_method  = "sni-only"
    acm_certificate_arn = aws_acm_certificate.ping_certificate.arn
  }
}

resource "cloudns_dns_record" "ping_cdn" {
  zone = "foxden.network"

  type  = "CNAME"
  name  = "ping"
  ttl   = 3600
  value = aws_cloudfront_distribution.ping_distribution.domain_name
}
