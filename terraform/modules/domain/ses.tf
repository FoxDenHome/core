data "aws_region" "current" {}

resource "aws_ses_domain_identity" "ses" {
  for_each = toset(var.ses ? ["main"] : [])
  domain   = var.domain
}

resource "cloudns_dns_record" "ses_verification_record" {
  for_each = aws_ses_domain_identity.ses
  zone     = cloudns_dns_zone.domain.id

  type  = "TXT"
  name  = "_amazonses"
  ttl   = 3600
  value = each.value.verification_token
}

resource "aws_ses_domain_dkim" "ses" {
  for_each = aws_ses_domain_identity.ses
  domain   = var.domain
}

resource "cloudns_dns_record" "ses_dkim_record" {
  count = var.ses ? 3 : 0 # AWS official guidance suggests count = 3 in their own Terraform module, so
  zone  = cloudns_dns_zone.domain.id

  type  = "CNAME"
  name  = "${aws_ses_domain_dkim.ses["main"].dkim_tokens[count.index]}._domainkey"
  ttl   = 3600
  value = "${aws_ses_domain_dkim.ses["main"].dkim_tokens[count.index]}.dkim.amazonses.com"
}

resource "aws_ses_domain_mail_from" "ses" {
  for_each = aws_ses_domain_identity.ses
  domain   = var.domain

  mail_from_domain = "ses-bounce.${var.domain}"
}

resource "cloudns_dns_record" "ses_mailfrom_mx" {
  for_each = aws_ses_domain_mail_from.ses
  zone     = cloudns_dns_zone.domain.id

  name     = "ses-bounce"
  type     = "MX"
  ttl      = 3600
  value    = "feedback-smtp.${data.aws_region.current.region}.amazonses.com"
  priority = 10
}

resource "cloudns_dns_record" "ses_mailfrom_txt" {
  for_each = aws_ses_domain_mail_from.ses
  zone     = cloudns_dns_zone.domain.id

  name  = "ses-bounce"
  type  = "TXT"
  ttl   = 3600
  value = "v=spf1 include:amazonses.com -all"
}
