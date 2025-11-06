# TODO: https://github.com/SuperBuker/terraform-provider-dns-he-net/issues/142
resource "dns-he-net_a" "static" {
  zone_id  = var.zone_id
  for_each = { for name, record in local.static_hosts : name => record if record.type == "A" }

  domain = each.value.fqdn
  ttl    = each.value.ttl
  data   = each.value.value
}

resource "dns-he-net_aaaa" "static" {
  zone_id  = var.zone_id
  for_each = { for name, record in local.static_hosts : name => record if record.type == "AAAA" }

  domain = each.value.fqdn
  ttl    = each.value.ttl
  data   = each.value.value
}

resource "dns-he-net_alias" "static" {
  zone_id  = var.zone_id
  for_each = { for name, record in local.static_hosts : name => record if record.type == "ALIAS" }

  domain = each.value.fqdn
  ttl    = each.value.ttl
  data   = each.value.value
}

resource "dns-he-net_cname" "static" {
  zone_id  = var.zone_id
  for_each = { for name, record in local.static_hosts : name => record if record.type == "CNAME" }

  domain = each.value.fqdn
  ttl    = each.value.ttl
  data   = each.value.value
}

resource "dns-he-net_mx" "static" {
  zone_id  = var.zone_id
  for_each = { for name, record in local.static_hosts : name => record if record.type == "MX" }

  domain   = each.value.fqdn
  ttl      = each.value.ttl
  data     = each.value.value
  priority = each.value.priority
}

resource "dns-he-net_ns" "static" {
  zone_id  = var.zone_id
  for_each = { for name, record in local.static_hosts : name => record if record.type == "NS" && record.name != "@" }

  domain = each.value.fqdn
  ttl    = each.value.ttl
  data   = each.value.value
}

resource "dns-he-net_ptr" "static" {
  zone_id  = var.zone_id
  for_each = { for name, record in local.static_hosts : name => record if record.type == "PTR" }

  domain = each.value.fqdn
  ttl    = each.value.ttl
  data   = each.value.value
}

# TODO: https://github.com/SuperBuker/terraform-provider-dns-he-net/issues/140
resource "dns-he-net_srv" "static" {
  zone_id  = var.zone_id
  for_each = { for name, record in local.static_hosts : name => record if record.type == "SRV" }

  domain   = each.value.fqdn
  ttl      = each.value.ttl
  target   = each.value.value
  port     = each.value.port
  weight   = each.value.weight
  priority = each.value.priority
}

resource "dns-he-net_txt" "static" {
  zone_id  = var.zone_id
  for_each = { for name, record in local.static_hosts : name => record if record.type == "TXT" }

  domain = each.value.fqdn
  ttl    = each.value.ttl
  data   = "\"${each.value.value}\""
}

resource "dns-he-net_a" "dynamic" {
  zone_id  = var.zone_id
  for_each = { for name, record in local.dyndns_hosts : name => record if record.type == "A" }

  domain = each.value.fqdn
  ttl    = each.value.ttl
  data   = each.value.value
  dynamic = true

  lifecycle {
    ignore_changes = [data]
  }
}

resource "dns-he-net_aaaa" "dynamic" {
  zone_id  = var.zone_id
  for_each = { for name, record in local.dyndns_hosts : name => record if record.type == "AAAA" }

  domain = each.value.fqdn
  ttl    = each.value.ttl
  data   = each.value.value
  dynamic = true

  lifecycle {
    ignore_changes = [data]
  }
}

resource "dns-he-net_txt" "dynamic" {
  zone_id  = var.zone_id
  for_each = { for name, record in local.dyndns_hosts : name => record if record.type == "TXT" }

  domain = each.value.fqdn
  ttl    = each.value.ttl
  data   = "\"${each.value.value}\""
  dynamic = true

  lifecycle {
    ignore_changes = [data]
  }
}

# resource "cloudns_dynamic_url" "dynamic" {
#   domain   = var.domain
#   for_each = local.dyndns_hosts

#   recordid = cloudns_dns_record.dynamic[each.key].id
# }

# output "dynamic_urls" {
#   value = [for id, value in local.dyndns_hosts : (merge({
#     url = cloudns_dynamic_url.dynamic[id].url,
#   }, value))]
# }
