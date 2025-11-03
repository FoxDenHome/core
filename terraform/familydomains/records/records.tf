locals {
  sub_cnames_raw = toset([
    "ftp",
    "mail",
    "mysql",
    "pop",
    "smtp",
  ])

  sub_cnames = setunion(
    local.sub_cnames_raw,
    [for cname in local.sub_cnames_raw : "www.${cname}"]
  )
}

resource "cloudns_dns_record" "cnames" {
  zone = var.zone

  for_each = local.sub_cnames

  type  = "CNAME"
  name  = each.value
  ttl   = 3600
  value = var.domain
}

resource "cloudns_dns_record" "mx" {
  zone = var.zone

  type     = "MX"
  name     = ""
  ttl      = 3600
  value    = var.server
  priority = 1
}

resource "cloudns_dns_record" "root" {
  zone = var.zone

  name  = ""
  type  = "ALIAS"
  ttl   = 3600
  value = var.server
}

resource "cloudns_dns_record" "www" {
  zone = var.zone

  name  = "www"
  type  = "CNAME"
  ttl   = 3600
  value = var.domain
}
