resource "aws_ses_domain_dkim" "ses" {
  domain = var.domain
}

resource "cloudns_dns_record" "ses_dkim_record" {
  zone = var.zone
  for_each = toset(aws_ses_domain_dkim.ses.dkim_tokens)

  type  = "CNAME"
  name  = "${each.value}._domainkey"
  ttl   = 3600
  value = "${each.value}.dkim.amazonses.com"
}
