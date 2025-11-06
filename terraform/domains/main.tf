data "external" "nix_dns_json" {
  program = ["${path.module}/nix.sh"]
  query   = {}
}

data "dns-he-net_zones" "zones" {}

locals {
  dns_json = jsondecode(data.external.nix_dns_json.result.json)

  zones_json   = local.dns_json["zones"]
  records_json = local.dns_json["records"]["external"]

  # TODO: https://github.com/SuperBuker/terraform-provider-dns-he-net/issues/141
  he_manual_zones = {
    "c.1.2.2.0.f.8.e.0.a.2.ip6.arpa" = 1055742
    "0.f.4.4.d.7.e.0.a.2.ip6.arpa"   = 927732
  }

  he_net_zone_map = merge(local.he_manual_zones, { for z in data.dns-he-net_zones.zones.zones : z.name => z.id })
}

# function izone -a zone; tofu import "module.domain[\"$zone\"].cloudns_dns_zone.domain" "$zone"; end

module "domain" {
  source   = "./domain"
  for_each = { for k, v in local.zones_json : k => v if v.registrar != "local" }

  domain      = each.key
  zone_id     = local.he_net_zone_map[each.key]
  ses         = each.value["ses"]
  registrar   = each.value["registrar"]
  nameservers = toset(each.value["nameserverList"])
  records     = local.records_json[each.key]
}

output "dynamic_urls" {
  value     = { for zone, domain in module.domain : zone => domain.dynamic_urls }
  sensitive = true
}

output "dnskey_records" {
  value = { for zone, domain in module.domain : zone => domain.dnskey_records }
}
