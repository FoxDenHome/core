data "external" "nix_dns_json" {
  program = ["${path.module}/domains.sh"]
  query   = {}
}

data "dns-he-net_domain_zones" "domains" {

}

locals {
  dns_json = jsondecode(data.external.nix_dns_json.result.json)

  zones_json   = local.dns_json["zones"]
  records_json = local.dns_json["records"]["external"]

  he_zone_ids = { for info in data.dns-he-net_domain_zones.domains.zones : info.name => info.zone_id }
}

module "domain" {
  source   = "./modules/domain"
  for_each = { for k, v in local.zones_json : k => v if v.registrar != "local" }

  domain     = each.key
  records    = local.records_json[each.key]
  he_zone_id = local.he_zone_ids[each.key]
}

output "he_dynamic_keys" {
  value     = merge([for m in module.domain : m.he_dynamic_keys]...)
  sensitive = true
}
