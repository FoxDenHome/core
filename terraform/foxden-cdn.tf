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

resource "cloudns_dns_record" "cdn_foxden_tls_validation" {
  depends_on = [fastly_tls_subscription.cdn_foxden]

  for_each = {
    # The following `for` expression (due to the outer {}) will produce an object with key/value pairs.
    # The 'key' is the domain name we've configured (e.g. a.example.com, b.example.com)
    # The 'value' is a specific 'challenge' object whose record_name matches the domain (e.g. record_name is _acme-challenge.a.example.com).
    for domain in fastly_tls_subscription.cdn_foxden.domains :
    domain => element([
      for obj in fastly_tls_subscription.cdn_foxden.managed_dns_challenges :
      obj if obj.record_name == "_acme-challenge.${domain}" # We use an `if` conditional to filter the list to a single element
    ], 0)                                                   # `element()` returns the first object in the list which should be the relevant 'challenge' object we need
  }

  zone = "foxden.network"

  name  = each.value.record_name
  type  = each.value.record_type
  value = each.value.record_value
  ttl   = 60
}

resource "fastly_tls_subscription_validation" "cdn_foxden" {
  subscription_id = fastly_tls_subscription.cdn_foxden.id
  depends_on      = [cloudns_dns_record.cdn_foxden_tls_validation]
}

data "fastly_tls_configuration" "cdn_foxden" {
  default    = true
  depends_on = [fastly_tls_subscription_validation.cdn_foxden]
}

resource "cloudns_dns_record" "cdn_foxden" {
  zone     = "foxden.network"
  for_each = toset([for record in data.fastly_tls_configuration.cdn_foxden.dns_records : record.record_value if record.record_type == "CNAME"])

  name  = "cdn"
  ttl   = 300
  type  = "CNAME"
  value = each.value
}

output "generated_records" {
  value = {
    "foxden.network" = [for r in setunion(
      values(cloudns_dns_record.cdn_foxden),
      values(cloudns_dns_record.cdn_foxden_tls_validation),
      ) : {
      type     = upper(r.type)
      fqdn     = r.name == "@" ? r.zone : "${r.name}.${r.zone}"
      name     = r.name
      ttl      = r.ttl
      value    = r.value
      horizon  = "*"
    }]
  }
}
