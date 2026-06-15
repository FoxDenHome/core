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
