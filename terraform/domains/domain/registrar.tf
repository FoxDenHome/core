locals {
  nameservers = toset([for ns in var.nameservers : trimsuffix(ns, ".")])

  ns_records    = [for rec in var.records : rec if rec["type"] == "NS"]
  alias_records = { for rec in var.records : "${rec["name"]}.${var.domain}" => rec if rec["type"] == "ALIAS" }

  ns_same_domain = endswith(tolist(local.nameservers)[0], ".${var.domain}")
  ns_to_upstream = local.ns_same_domain ? { for rec in local.ns_records :
    trimsuffix(rec["value"], ".") =>
    trimsuffix(local.alias_records[trimsuffix(rec["value"], ".")]["value"], ".")
  } : {}
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
      glue_ips = local.ns_same_domain ? [
        data.dns_a_record_set.ns[name_server.key].addrs[0],
        data.dns_aaaa_record_set.ns[name_server.key].addrs[0],
      ] : []
    }
  }
}
