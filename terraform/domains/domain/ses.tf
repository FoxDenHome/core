data "aws_region" "current" {}

resource "aws_ses_domain_identity" "ses" {
  count  = var.ses ? 1 : 0
  domain = var.domain
}

resource "cloudns_dns_record" "ses_verification_record" {
  for_each = aws_ses_domain_identity.ses
  zone     = cloudns_dns_zone.domain.id

  type  = "TXT"
  name  = "_amazonses"
  ttl   = 3600
  value = each.value.ses.verification_token
}

resource "aws_ses_domain_dkim" "ses" {
  count  = var.ses ? 1 : 0
  domain = var.domain
}

resource "cloudns_dns_record" "ses_dkim_record" {
  for_each = toset(aws_ses_domain_dkim.ses.dkim_tokens)
  zone     = cloudns_dns_zone.domain.id

  type  = "CNAME"
  name  = "${each.value}._domainkey"
  ttl   = 3600
  value = "${each.value}.dkim.amazonses.com"
}

resource "aws_ses_domain_mail_from" "ses" {
  count            = var.ses ? 1 : 0
  domain           = var.domain
  mail_from_domain = "ses-bounce.${var.domain}"
}

resource "cloudns_dns_record" "ses_mailfrom_mx" {
  count = var.ses ? 1 : 0
  zone  = cloudns_dns_zone.domain.id

  name     = "ses-bounce"
  type     = "MX"
  ttl      = 3600
  value    = "feedback-smtp.${data.aws_region.current.region}.amazonses.com"
  priority = 10
}

resource "cloudns_dns_record" "ses_mailfrom_txt" {
  count = var.ses ? 1 : 0
  zone  = cloudns_dns_zone.domain.id

  name  = "ses-bounce"
  type  = "TXT"
  ttl   = 3600
  value = "v=spf1 include:amazonses.com -all"
}
