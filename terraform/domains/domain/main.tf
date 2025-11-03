locals {
  has_vanity_ns   = var.vanity_nameserver != null
  ns_same_domain  = local.has_vanity_ns ? (var.vanity_nameserver.name == var.domain) : false
  vanity_ns_list  = local.has_vanity_ns ? var.vanity_nameserver.list : null
  cloudns_ns_list = ["pns41.cloudns.net", "pns42.cloudns.net", "pns43.cloudns.net", "pns44.cloudns.net"]

  used_ns_list = local.has_vanity_ns ? local.vanity_ns_list : local.cloudns_ns_list
}

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

output "zone" {
  value = cloudns_dns_zone.domain.id
}

/*
function izone -a zone
  tofu import "module.domain[\"$zone\"].cloudns_dns_zone.domain" "$zone"
end
*/
