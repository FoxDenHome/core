resource "cloudns_dns_record" "spf" {
  count = (var.ses || var.fastmail) ? 1 : 0
  zone  = cloudns_dns_zone.domain.id

  name = ""
  type = "TXT"
  ttl  = 3600
  value = join(" ", compact([
    "v=spf1",
    var.fastmail ? "include:spf.messagingengine.com" : "",
    var.ses ? "include:amazonses.com" : "",
    "mx",
    "~all",
  ]))
}

resource "cloudns_dns_record" "dmarc" {
  count = (var.ses || var.fastmail) ? 1 : 0
  zone  = cloudns_dns_zone.domain.id

  name  = "_dmarc"
  type  = "TXT"
  ttl   = 3600
  value = "v=DMARC1;p=quarantine;pct=100"
}
# FastMail
resource "cloudns_dns_record" "smtp" {
  count = var.fastmail ? 2 : 0
  zone  = cloudns_dns_zone.domain.id

  name     = ""
  type     = "MX"
  ttl      = 3600
  value    = "in${count.index + 1}-smtp.messagingengine.com"
  priority = 10 * (count.index + 1)
}

resource "cloudns_dns_record" "dkim" {
  count = var.fastmail ? 3 : 0
  zone  = cloudns_dns_zone.domain.id

  name  = "fm${count.index + 1}._domainkey"
  type  = "CNAME"
  ttl   = 3600
  value = "fm${count.index + 1}.${var.domain}.dkim.fmhosted.com"
}

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
