locals {
  records_uppercase_type = [for r in var.records : merge(r, { type = upper(r.type) })]

  record_map = zipmap([for r in local.records_uppercase_type : "${r.type};${r.name};${r.value}"], local.records_uppercase_type)

  static_hosts = { for name, record in local.record_map : name => record if !record.dynDns }
  dyndns_hosts = { for name, record in local.record_map : name => record if record.dynDns }

  dotname_refer_types = toset(["CNAME", "ALIAS", "NS"])

  dyndns_value_map = {
    A    = "127.0.0.1"
    AAAA = "::1"
  }
}

resource "cloudns_dns_record" "static" {
  zone     = var.zone
  for_each = local.static_hosts

  type     = each.value.type
  name     = each.value.name == "@" ? "" : each.value.name
  ttl      = each.value.ttl
  priority = each.value.priority
  port     = each.value.port
  weight   = each.value.weight
  value    = contains(local.dotname_refer_types, each.value.type) ? trimsuffix(each.value.value, ".") : each.value.value
}

resource "cloudns_dns_record" "dynamic" {
  zone     = var.zone
  for_each = local.dyndns_hosts

  type  = each.value.type
  name  = each.value.name == "@" ? "" : each.value.name
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
