locals {
  subdomain_dotend   = (var.subdomain == "") ? "" : "${var.subdomain}."
  subdomain_dotstart = (var.subdomain == "") ? "" : ".${var.subdomain}"
  full_domain        = "${local.subdomain_dotend}${var.domain}"
}

resource "aws_ses_domain_identity" "ses" {
  domain = local.full_domain
}
