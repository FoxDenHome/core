locals {
  subdomain_dotend   = (var.subdomain == "") ? "" : "${var.subdomain}."
  subdomain_dotstart = (var.subdomain == "") ? "" : ".${var.subdomain}"
  full_domain        = "${local.subdomain_dotend}${var.domain}"
}

data "aws_region" "current" {}

resource "aws_ses_domain_identity" "ses" {
  domain = local.full_domain
}

resource "cloudns_dns_record" "ses_verification_record" {
  zone = var.zone

  type  = "TXT"
  name  = "_amazonses${local.subdomain_dotstart}"
  ttl   = 3600
  value = aws_ses_domain_identity.ses.verification_token
}
