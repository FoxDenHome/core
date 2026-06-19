resource "fastly_service_vcl" "cdn_foxden" {
  name = "FoxDen CDN"

  backend {
    address = "127.0.0.1"
    name    = "dummy"
    port    = 1
  }

  vcl {
    name    = "foxden_cdn_vcl"
    content = file("${path.module}/foxden-cdn.vcl")
    main    = true
  }

  dictionary {
    name = "static_root"
  }
}

locals {
  static_response_path = "${path.module}/foxden-cdn-static"
}

resource "fastly_service_dictionary_items" "cdn_foxden_static_root" {
  service_id    = fastly_service_vcl.cdn_foxden.id
  dictionary_id = one(fastly_service_vcl.cdn_foxden.dictionary).dictionary_id

  manage_items = true
  items        = { for file in fileset(local.static_response_path, "**") : "/${file}" => filebase64("${local.static_response_path}/${file}") }
}


resource "fastly_domain" "cdn_foxden" {
  fqdn        = "cdn.foxden.network"
  service_id  = fastly_service_vcl.cdn_foxden.id
  description = "FoxDen CDN domain"
}

resource "fastly_tls_subscription" "cdn_foxden" {
  domains               = [fastly_domain.cdn_foxden.fqdn]
  certificate_authority = "certainly"
}

data "fastly_tls_configuration" "cdn_foxden" {
  default = true
}

resource "dns-he-net_cname" "cdn_foxden" {
  zone_id  = local.he_zone_ids["foxden.network"]
  for_each = toset([for record in data.fastly_tls_configuration.cdn_foxden.dns_records : record.record_value if record.record_type == "CNAME"])

  domain = "cdn.foxden.network"
  ttl    = 300
  data   = trimsuffix(each.value, ".")
}
