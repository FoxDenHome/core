locals {
  dns_json = jsondecode(data.external.nix_dns_json.result.json)

  zones_json   = local.dns_json["zones"]
  records_json = local.dns_json["records"]["external"]
}

data "external" "nix_dns_json" {
  program = ["${path.module}/nix.sh"]
  query   = {}
}

# function izone -a zone; tofu import "module.domain[\"$zone\"].cloudns_dns_zone.domain" "$zone"; end

module "domain" {
  source   = "./domain"
  for_each = { for k, v in local.zones_json : k => v if v.registrar != "local" }

  domain      = each.key
  ses         = each.value["ses"]
  registrar   = each.value["registrar"]
  nameservers = toset(each.value["nameserverList"])
  records     = local.records_json[each.key]
}

output "dynamic_urls" {
  value = { for zone, domain in module.domain : zone => domain.dynamic_urls }
}

output "dnskey_records" {
  value = { for zone, domain in module.domain : zone => domain.dnskey_records }
}
