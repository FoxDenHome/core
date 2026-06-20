locals {
  records_ext = [for r in var.records : merge(r, {
    type = upper(r.type)
    host = r.name == "@" ? "" : r.name
    fqdn = r.name == "@" ? var.domain : "${r.name}.${var.domain}"
  })]

  record_map = zipmap([for r in local.records_ext : "${r.type};${r.name};${r.value}"], local.records_ext)

  static_hosts = { for name, record in local.record_map : name => record if !record.dynDns }
  dyndns_hosts = { for name, record in local.record_map : name => record if record.dynDns }

  dyndns_hosts_fqdns  = toset([for _, v in local.dyndns_hosts : v.fqdn])
  dyndns_ipv4_by_fqdn = { for _, v in local.dyndns_hosts : v.fqdn => v.value if v.type == "A" }
  dyndns_ipv6_by_fqdn = { for _, v in local.dyndns_hosts : v.fqdn => v.value if v.type == "AAAA" }
}

resource "dns-he-net_a" "static" {
  zone_id  = var.he_zone_id
  for_each = { for k, v in local.static_hosts : k => v if v.type == "A" }

  domain = each.value.fqdn
  ttl    = each.value.ttl
  data   = trimsuffix(each.value.value, ".")
}

resource "dns-he-net_aaaa" "static" {
  zone_id  = var.he_zone_id
  for_each = { for k, v in local.static_hosts : k => v if v.type == "AAAA" }

  domain = each.value.fqdn
  ttl    = each.value.ttl
  data   = trimsuffix(each.value.value, ".")
}

resource "dns-he-net_alias" "static" {
  zone_id  = var.he_zone_id
  for_each = { for k, v in local.static_hosts : k => v if v.type == "ALIAS" }

  domain = each.value.fqdn
  ttl    = each.value.ttl
  data   = trimsuffix(each.value.value, ".")
}

resource "dns-he-net_cname" "static" {
  zone_id  = var.he_zone_id
  for_each = { for k, v in local.static_hosts : k => v if v.type == "CNAME" }

  domain = each.value.fqdn
  ttl    = each.value.ttl
  data   = trimsuffix(each.value.value, ".")
}

resource "dns-he-net_mx" "static" {
  zone_id  = var.he_zone_id
  for_each = { for k, v in local.static_hosts : k => v if v.type == "MX" }

  domain   = each.value.fqdn
  ttl      = each.value.ttl
  data     = trimsuffix(each.value.value, ".")
  priority = each.value.priority
}

resource "dns-he-net_ns" "static" {
  zone_id  = var.he_zone_id
  for_each = { for k, v in local.static_hosts : k => v if v.type == "NS" }

  domain = each.value.fqdn
  ttl    = each.value.ttl
  data   = trimsuffix(each.value.value, ".")
}

resource "dns-he-net_srv" "static" {
  zone_id  = var.he_zone_id
  for_each = { for k, v in local.static_hosts : k => v if v.type == "SRV" }

  domain   = each.value.fqdn
  ttl      = each.value.ttl
  port     = each.value.port
  priority = each.value.priority
  weight   = each.value.weight
  target   = trimsuffix(each.value.value, ".")
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
  data   = join(" ", [for partList in chunklist(split("", each.value.value), 255) : "\"${join("", partList)}\""])
}

resource "dns-he-net_a" "dynamic" {
  zone_id  = var.he_zone_id
  for_each = { for _, v in local.dyndns_hosts : v.fqdn => v if v.type == "A" }

  domain  = each.value.fqdn
  ttl     = each.value.ttl
  data    = "127.0.0.1"
  dynamic = true

  lifecycle {
    ignore_changes = [data]
  }
}

resource "dns-he-net_aaaa" "dynamic" {
  zone_id  = var.he_zone_id
  for_each = { for _, v in local.dyndns_hosts : v.fqdn => v if v.type == "AAAA" }

  domain  = each.value.fqdn
  ttl     = each.value.ttl
  data    = "::1"
  dynamic = true

  lifecycle {
    ignore_changes = [data]
  }
}

resource "random_password" "he_dynamic_key" {
  for_each = local.dyndns_hosts_fqdns

  length  = 24
  special = false
}

resource "dns-he-net_ddnskey" "dynamic" {
  zone_id  = var.he_zone_id
  for_each = local.dyndns_hosts_fqdns

  domain = each.key
  key    = random_password.he_dynamic_key[each.key].result
}

output "he_dynamic_keys" {
  value = { for fqdn, record in dns-he-net_ddnskey.dynamic : fqdn => {
    key  = random_password.he_dynamic_key[fqdn].result
    ipv4 = try(local.dyndns_ipv4_by_fqdn[fqdn], null)
    ipv6 = try(local.dyndns_ipv6_by_fqdn[fqdn], null)
  } }
  sensitive = true
}
