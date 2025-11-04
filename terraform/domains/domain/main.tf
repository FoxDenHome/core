module "ses" {
  count     = var.ses ? 1 : 0
  source    = "./ses"
  zone      = cloudns_dns_zone.domain.id
  domain    = var.domain
  subdomain = ""
}

resource "cloudns_dns_zone" "domain" {
  domain = var.domain
  type   = "master"
}

/*
function izone -a zone
  tofu import "module.domain[\"$zone\"].cloudns_dns_zone.domain" "$zone"
end
*/
