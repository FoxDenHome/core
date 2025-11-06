locals {
  records_ext = [for r in var.records : merge(r, {
    type  = upper(r.type)
    host  = r.name == "@" ? "" : "${r.name}"
    fqdn  = r.name == "@" ? var.domain : "${r.name}.${var.domain}"
    value = contains(local.dotname_refer_types, upper(r.type)) ? trimsuffix(r.value, ".") : r.value
  })]

  record_map = zipmap([for r in local.records_ext : "${r.type};${r.name};${r.value}"], local.records_ext)

  static_hosts = { for name, record in local.record_map : name => record if !record.dynDns && !contains(local.ignore_record_types, record.type) }
  dyndns_hosts = { for name, record in local.record_map : name => record if record.dynDns && !contains(local.ignore_record_types, record.type) }

  dotname_refer_types = toset(["CNAME", "ALIAS", "NS", "SRV", "MX"])
  ignore_record_types = toset(["SOA"])

  dyndns_value_map = {
    A    = "127.0.0.1"
    AAAA = "::1"
  }
}

resource "cloudns_dns_record" "static" {
  zone     = cloudns_dns_zone.domain.id
  for_each = local.static_hosts

  type     = each.value.type
  name     = each.value.host
  ttl      = each.value.ttl
  priority = each.value.priority
  port     = each.value.port
  weight   = each.value.weight
  value    = each.value.value
}

resource "cloudns_dns_record" "dynamic" {
  zone     = cloudns_dns_zone.domain.id
  for_each = local.dyndns_hosts

  type  = each.value.type
  name  = each.value.host
  ttl   = each.value.ttl
  value = local.dyndns_value_map[each.value.type]

  lifecycle {
    ignore_changes = [value]
  }
}

resource "cloudns_dynamic_url" "dynamic" {
  domain   = var.domain
  for_each = local.dyndns_hosts

  recordid = cloudns_dns_record.dynamic[each.key].id
}

output "dynamic_urls" {
  value = [for id, value in local.dyndns_hosts : (merge({
    url = cloudns_dynamic_url.dynamic[id].url,
  }, value))]
}
