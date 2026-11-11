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

  # Items are owned by foxden-vpn-portal (VPN provisioning blobs), not terraform
  dictionary {
    name = "vpn_peers"
  }
}

data "fastly_tls_configuration" "cdn_foxden" {
  default = true
}

locals {
  static_response_path = "${path.module}/foxden-cdn-static"
  domains = toset([
    "cdn.foxden.network",
    "foxden.network",
    "www.foxden.network"
  ])

  cname_record = one([for record in data.fastly_tls_configuration.cdn_foxden.dns_records : record.record_value if record.record_type == "CNAME"])
}

resource "fastly_service_dictionary_items" "cdn_foxden_static_root" {
  service_id    = fastly_service_vcl.cdn_foxden.id
  dictionary_id = one([for d in fastly_service_vcl.cdn_foxden.dictionary : d.dictionary_id if d.name == "static_root"])

  manage_items = true
  items        = { for file in fileset(local.static_response_path, "**") : "/${file}" => filebase64("${local.static_response_path}/${file}") }
}


resource "fastly_domain" "cdn_foxden" {
  for_each    = local.domains
  fqdn        = each.key
  service_id  = fastly_service_vcl.cdn_foxden.id
  description = "FoxDen CDN domain"
}

resource "fastly_tls_subscription" "cdn_foxden" {
  domains               = local.domains
  certificate_authority = "certainly"

  depends_on = [fastly_domain.cdn_foxden]
}

resource "cloudns_dns_record" "cdn_foxden" {
  for_each = local.domains

  zone  = module.cloudns_domain["foxden.network"].zone
  type  = each.key == "foxden.network" ? "ALIAS" : "CNAME"
  name  = each.key == "foxden.network" ? "" : trimsuffix(each.key, ".foxden.network")
  ttl   = 300
  value = trimsuffix(local.cname_record, ".")
}
