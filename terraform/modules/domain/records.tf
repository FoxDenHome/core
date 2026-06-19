locals {
  records_ext = [for r in var.records : merge(r, {
    type       = upper(r.type)
    host       = r.name == "@" ? "" : r.name
    fqdn       = r.name == "@" ? var.domain : "${r.name}.${var.domain}"
    dotlessval = contains(local.dotname_refer_types, upper(r.type)) ? trimsuffix(r.value, ".") : r.value
    strval     = upper(r.type) == "SRV" ? "${r.priority} ${r.weight} ${r.port} ${r.value}" : upper(r.type) == "SSHFP" ? "${r.algorithm} ${r.fptype} ${r.value}" : r.value
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
  value     = each.value.dotlessval
  algorithm = each.value.algorithm
  fptype    = each.value.fptype
}

resource "inwx_nameserver_record" "static" {
  domain   = inwx_nameserver.domain[0].domain
  for_each = local.use_inwx ? { for k, v in local.static_hosts : k => v if v.type != "SSHFP" && !(v.type == "NS" && v.name == "@") } : {}

  type    = each.value.type
  name    = each.value.name
  prio    = each.value.priority
  ttl     = each.value.ttl
  content = each.value.strval
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
