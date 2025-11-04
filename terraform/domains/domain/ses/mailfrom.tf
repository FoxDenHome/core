resource "aws_ses_domain_mail_from" "ses_mailfrom" {
  domain           = var.domain
  mail_from_domain = "ses-bounce.${var.domain}"
}

resource "cloudns_dns_record" "ses_mailfrom_mx" {
  zone = var.zone

  name     = "ses-bounce"
  type     = "MX"
  ttl      = 3600
  value    = "feedback-smtp.${data.aws_region.current.region}.amazonses.com"
  priority = 10
}

resource "cloudns_dns_record" "ses_mailfrom_txt" {
  zone = var.zone

  name  = "ses-bounce"
  type  = "TXT"
  ttl   = 3600
  value = "v=spf1 include:amazonses.com -all"
}
