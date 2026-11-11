data "external" "nix_dns_json" {
  program = ["${path.module}/domains.sh"]
  query   = {}
}

locals {
  dns_json = jsondecode(data.external.nix_dns_json.result.json)

  zones_json   = local.dns_json["zones"]
  records_json = local.dns_json["records"]["external"]
  public_zones = { for k, v in local.zones_json : k => v if v.registrar != "local" }

  upstream_nameservers = [for ns in local.dns_json["authorities"]["upstream"]["nameservers"] : trimsuffix(ns, ".")]

  # ACME DNS-01: every dynamic TXT record _acme-challenge.<name> becomes a
  # CNAME to _acme-challenge.<name>.<group>.acme.foxden.network. Each group is
  # a zone of its own, so an API sub-user delegated only that zone can answer
  # the challenges of its group and nothing else. lego follows the CNAME.
  acme_parent = "foxden.network"
  acme_challenges = merge([for zone, _ in local.public_zones : {
    for r in local.records_json[zone] : (r.name == "@" ? zone : "${r.name}.${zone}") => "${
      r.acmeGroup != null ? r.acmeGroup : replace(trimprefix(r.name == "@" ? zone : "${r.name}.${zone}", "_acme-challenge."), ".", "-")
    }.acme.${local.acme_parent}" if r.dynDns && upper(r.type) == "TXT"
  }]...)
  acme_zones = toset(values(local.acme_challenges))
}

module "cloudns_domain" {
  source   = "./modules/cloudns-domain"
  for_each = local.public_zones

  domain      = each.key
  nameservers = [for ns in each.value.nameserverList : trimsuffix(ns, ".")]
  records     = local.records_json[each.key]
  acme_zones  = local.acme_challenges
}

resource "cloudns_dns_zone" "acme" {
  for_each = local.acme_zones

  domain      = each.key
  type        = "master"
  nameservers = local.upstream_nameservers

  lifecycle {
    # Changes would replace the zone; see modules/cloudns-domain
    ignore_changes = [nameservers]
  }
}

resource "cloudns_dns_record" "acme_delegation" {
  for_each = { for pair in setproduct(local.acme_zones, local.upstream_nameservers) : "${pair[0]};${pair[1]}" => {
    zone = pair[0]
    ns   = pair[1]
  } }

  zone  = module.cloudns_domain[local.acme_parent].zone
  type  = "NS"
  name  = trimsuffix(cloudns_dns_zone.acme[each.value.zone].domain, ".${local.acme_parent}")
  ttl   = 3600
  value = each.value.ns
}

# fqdn => { ipv4, ipv6, ipv6_suffix }: dynamic URL keys for the routers
output "cloudns_dynamic_keys" {
  value     = merge([for m in module.cloudns_domain : m.dynamic_keys]...)
  sensitive = true
}

# _acme-challenge.<name> => ClouDNS zone its TXT record goes into. Each zone
# needs an API sub-user (made by hand) for whoever requests the certificate.
output "acme_zones" {
  value = local.acme_challenges
}
