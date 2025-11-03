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
    for_each = local.used_ns_list
    content {
      name = name_server.value
      glue_ips = local.ns_same_domain ? [
        data.dns_a_record_set.ns[name_server.key].addrs[0],
        data.dns_aaaa_record_set.ns[name_server.key].addrs[0],
      ] : []
    }
  }
}
