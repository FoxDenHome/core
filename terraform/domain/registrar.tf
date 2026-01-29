locals {
  nameservers = toset([for ns in var.nameservers : trimsuffix(ns, ".")])

  ns_records    = [for _, rec in local.record_map : rec if rec["type"] == "NS"]
  alias_records = { for _, rec in local.record_map : "${rec["name"]}.${var.domain}" => rec if rec["type"] == "ALIAS" }

  ns_to_upstream = { for rec in local.ns_records :
    trimsuffix(rec["value"], ".") =>
    trimsuffix(local.alias_records[trimsuffix(rec["value"], ".")]["value"], ".")
    if endswith(trimsuffix(rec["value"], "."), ".${var.domain}")
  }
}

data "dns_a_record_set" "ns" {
  for_each = local.ns_to_upstream
  host     = each.value
}

data "dns_aaaa_record_set" "ns" {
  for_each = local.ns_to_upstream
  host     = each.value
}

resource "aws_route53domains_registered_domain" "domain" {
  count       = var.registrar == "aws" ? 1 : 0
  domain_name = var.domain

  auto_renew    = true
  transfer_lock = true

  admin_privacy      = true
  registrant_privacy = true
  tech_privacy       = true
  billing_privacy    = true

  dynamic "name_server" {
    for_each = local.nameservers
    content {
      name = name_server.value
      glue_ips = lookup(local.ns_to_upstream, name_server.value, null) != null ? [
        data.dns_a_record_set.ns[name_server.value].addrs[0],
        data.dns_aaaa_record_set.ns[name_server.value].addrs[0],
      ] : []
    }
  }
}
