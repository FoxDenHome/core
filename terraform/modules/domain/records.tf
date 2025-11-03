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

resource "cloudns_dns_record" "ns_ns" {
  count = length(local.used_ns_list)
  zone  = cloudns_dns_zone.domain.id

  name  = ""
  type  = "NS"
  ttl   = 86400
  value = local.used_ns_list[count.index]
}
