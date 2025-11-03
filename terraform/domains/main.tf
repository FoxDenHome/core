locals {
  dns_json = jsondecode(data.external.nix_dns_json.result.json)

  zones_json   = local.dns_json["zones"]
  records_json = local.dns_json["records"]["external"]
}

data "external" "nix_dns_json" {
  program = ["${path.module}/nix.sh"]
  query   = {}
}

module "domain" {
  source   = "../modules/domain"
  for_each = { for k, v in local.zones_json : k => v if v.registrar != "local" }

  domain            = each.key
  fastmail          = !endswith(each.key, ".arpa")
  ses               = !endswith(each.key, ".arpa")
  root_aname        = null
  add_www_cname     = false
  vanity_nameserver = local.vanity_nameservers[each.value["vanityNameserver"]]
  registrar         = each.value["registrar"]
}

module "domain_jsonrecords" {
  source   = "./jsonrecords"
  for_each = { for k, v in local.records_json : k => v if local.zones_json[k].registrar != "local" }

  domain  = each.key
  zone    = module.domain[each.key].zone
  records = each.value
}

output "dynamic_urls" {
  value = flatten([for domain in module.domain_jsonrecords : domain.dynamic_urls])
}
