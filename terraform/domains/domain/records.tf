# VanityNS
resource "cloudns_dns_record" "ns_ns" {
  count = length(local.used_ns_list)
  zone  = cloudns_dns_zone.domain.id

  name  = ""
  type  = "NS"
  ttl   = 86400
  value = local.used_ns_list[count.index]
}

data "dns_a_record_set" "ns" {
  count = local.ns_same_domain ? length(local.vanity_ns_list) : 0

  host = local.cloudns_ns_list[count.index]
}

data "dns_aaaa_record_set" "ns" {
  count = local.ns_same_domain ? length(local.vanity_ns_list) : 0

  host = local.cloudns_ns_list[count.index]
}

resource "cloudns_dns_record" "ns_a" {
  count = local.ns_same_domain ? length(local.vanity_ns_list) : 0
  zone  = cloudns_dns_zone.domain.id

  name  = "ns${count.index + 1}"
  type  = "A"
  ttl   = 86400
  value = data.dns_a_record_set.ns[count.index].addrs[0]
}

resource "cloudns_dns_record" "ns_aaaa" {
  count = local.ns_same_domain ? length(local.vanity_ns_list) : 0
  zone  = cloudns_dns_zone.domain.id

  name  = "ns${count.index + 1}"
  type  = "AAAA"
  ttl   = 86400
  value = data.dns_aaaa_record_set.ns[count.index].addrs[0]
}
