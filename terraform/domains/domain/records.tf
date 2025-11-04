locals {
  records_uppercase_type = [for r in var.records : merge(r, { type = upper(r.type) })]

  record_map = zipmap([for r in local.records_uppercase_type : "${r.type};${r.name};${r.value}"], local.records_uppercase_type)

  static_hosts = { for name, record in local.record_map : name => record if !record.dynDns && !contains(local.ignore_record_types, upper(record.type)) }
  dyndns_hosts = { for name, record in local.record_map : name => record if record.dynDns && !contains(local.ignore_record_types, upper(record.type)) }

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
  name     = each.value.name == "@" ? "" : each.value.name
  ttl      = each.value.ttl
  priority = each.value.priority
  port     = each.value.port
  weight   = each.value.weight
  value    = contains(local.dotname_refer_types, upper(each.value.type)) ? trimsuffix(each.value.value, ".") : each.value.value
}

resource "cloudns_dns_record" "dynamic" {
  zone     = cloudns_dns_zone.domain.id
  for_each = local.dyndns_hosts

  type  = each.value.type
  name  = each.value.name == "@" ? "" : each.value.name
  ttl   = each.value.ttl
  value = local.dyndns_value_map[upper(each.value.type)]

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
