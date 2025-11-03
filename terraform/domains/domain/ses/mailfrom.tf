locals {
  mail_from_host   = "${var.mail_from_subdomain}${local.subdomain_dotstart}"
  mail_from_domain = "${var.mail_from_subdomain}.${local.full_domain}"
}

data "aws_region" "current" {}

resource "aws_ses_domain_mail_from" "ses_mailfrom" {
  domain           = local.full_domain
  mail_from_domain = local.mail_from_domain
}

resource "cloudns_dns_record" "ses_mailfrom_mx" {
  zone = var.zone

  name     = local.mail_from_host
  type     = "MX"
  ttl      = 3600
  value    = "feedback-smtp.${data.aws_region.current.name}.amazonses.com"
  priority = 10
}

resource "cloudns_dns_record" "ses_mailfrom_txt" {
  zone = var.zone

  name  = local.mail_from_host
  type  = "TXT"
  ttl   = 3600
  value = "v=spf1 include:amazonses.com -all"
}
