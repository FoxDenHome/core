locals {
  records_ext = [for r in var.records : merge(r, {
    type  = upper(r.type)
    host  = r.name == "@" ? "" : r.name
    fqdn  = r.name == "@" ? var.domain : "${r.name}.${var.domain}"
    value = contains(local.dotname_refer_types, upper(r.type)) ? trimsuffix(r.value, ".") : r.value
  })]

  record_map = zipmap([for r in local.records_ext : "${r.type};${r.name};${r.value}"], local.records_ext)

  static_hosts = { for name, record in local.record_map : name => record if !record.dynDns }
  dyndns_hosts = { for name, record in local.record_map : name => record if record.dynDns }

  dotname_refer_types = toset(["CNAME", "ALIAS", "NS", "SRV", "MX"])

  dyndns_value_map = {
    A    = "127.0.0.1"
    AAAA = "::1"
  }
}

resource "cloudns_dns_record" "static" {
  zone     = cloudns_dns_zone.domain.id
  for_each = local.static_hosts

  type      = each.value.type
  name      = each.value.host
  ttl       = each.value.ttl
  priority  = each.value.priority
  port      = each.value.port
  weight    = each.value.weight
  value     = each.value.value
  algorithm = each.value.algorithm
  fptype    = each.value.fptype
}

resource "dns-he-net_a" "static" {
  zone_id  = var.he_zone_id
  for_each = { for k, v in local.static_hosts : k => v if v.type == "A" }

  domain = each.value.fqdn
  ttl    = each.value.ttl
  data   = each.value.value
}

resource "dns-he-net_aaaa" "static" {
  zone_id  = var.he_zone_id
  for_each = { for k, v in local.static_hosts : k => v if v.type == "AAAA" }

  domain = each.value.fqdn
  ttl    = each.value.ttl
  data   = each.value.value
}

resource "dns-he-net_alias" "static" {
  zone_id  = var.he_zone_id
  for_each = { for k, v in local.static_hosts : k => v if v.type == "ALIAS" }

  domain = each.value.fqdn
  ttl    = each.value.ttl
  data   = each.value.value
}

resource "dns-he-net_cname" "static" {
  zone_id  = var.he_zone_id
  for_each = { for k, v in local.static_hosts : k => v if v.type == "CNAME" }

  domain = each.value.fqdn
  ttl    = each.value.ttl
  data   = each.value.value
}

resource "dns-he-net_mx" "static" {
  zone_id  = var.he_zone_id
  for_each = { for k, v in local.static_hosts : k => v if v.type == "MX" }

  domain   = each.value.fqdn
  ttl      = each.value.ttl
  data     = each.value.value
  priority = each.value.priority
}

resource "dns-he-net_ns" "static" {
  zone_id  = var.he_zone_id
  for_each = { for k, v in local.static_hosts : k => v if v.type == "NS" }

  domain = each.value.fqdn
  ttl    = each.value.ttl
  data   = each.value.value
}

resource "dns-he-net_srv" "static" {
  zone_id  = var.he_zone_id
  for_each = { for k, v in local.static_hosts : k => v if v.type == "SRV" }

  domain   = each.value.fqdn
  ttl      = each.value.ttl
  port     = each.value.port
  priority = each.value.priority
  weight   = each.value.weight
  target   = each.value.value
}

resource "dns-he-net_sshfp" "static" {
  zone_id  = var.he_zone_id
  for_each = { for k, v in local.static_hosts : k => v if v.type == "SSHFP" }

  domain = each.value.fqdn
  ttl    = each.value.ttl
  data   = "${each.value.algorithm} ${each.value.fptype} ${each.value.value}"
}

resource "dns-he-net_txt" "static" {
  zone_id  = var.he_zone_id
  for_each = { for k, v in local.static_hosts : k => v if v.type == "TXT" }

  domain = each.value.fqdn
  ttl    = each.value.ttl
  data   = "\"${each.value.value}\""
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
  sensitive = true
}
