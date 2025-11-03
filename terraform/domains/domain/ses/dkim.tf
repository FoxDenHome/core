resource "aws_ses_domain_dkim" "ses" {
  domain = local.full_domain
}

resource "cloudns_dns_record" "ses_dkim_record" {
  count = 3

  zone = var.zone

  type  = "CNAME"
  name  = "${aws_ses_domain_dkim.ses.dkim_tokens[count.index]}._domainkey${local.subdomain_dotstart}"
  ttl   = 3600
  value = "${aws_ses_domain_dkim.ses.dkim_tokens[count.index]}.dkim.amazonses.com"
}
