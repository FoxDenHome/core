resource "aws_ses_domain_identity" "ses" {
  for_each = toset(var.ses ? ["main"] : [])
  domain   = var.domain
}

resource "dns-he-net_txt" "ses_verification" {
  for_each = aws_ses_domain_identity.ses
  zone_id  = var.he_zone_id

  domain = "_amazonses.${var.domain}"
  ttl    = 3600
  data   = "\"${each.value.verification_token}\""
}

resource "aws_ses_domain_dkim" "ses" {
  for_each = aws_ses_domain_identity.ses
  domain   = var.domain
}

resource "dns-he-net_cname" "ses_dkim" {
  count   = var.ses ? 3 : 0 # AWS official guidance suggests count = 3 in their own Terraform module, so
  zone_id = var.he_zone_id

  domain = "${aws_ses_domain_dkim.ses["main"].dkim_tokens[count.index]}._domainkey.${var.domain}"
  ttl    = 3600
  data   = "${aws_ses_domain_dkim.ses["main"].dkim_tokens[count.index]}.dkim.amazonses.com"
}

resource "aws_ses_domain_mail_from" "ses" {
  for_each = aws_ses_domain_identity.ses
  domain   = var.domain

  mail_from_domain = "ses-bounce.${var.domain}"
}

resource "dns-he-net_mx" "ses_mailfrom" {
  for_each = aws_ses_domain_mail_from.ses
  zone_id  = var.he_zone_id

  domain   = "ses-bounce.${var.domain}"
  ttl      = 3600
  data     = "feedback-smtp.eu-west-1.amazonses.com"
  priority = 10
}

resource "dns-he-net_txt" "ses_mailfrom" {
  for_each = aws_ses_domain_mail_from.ses
  zone_id  = var.he_zone_id

  domain = "ses-bounce.${var.domain}"
  ttl    = 3600
  data   = "\"v=spf1 include:amazonses.com -all\""
}
