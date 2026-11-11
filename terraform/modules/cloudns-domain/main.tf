locals {
  # ClouDNS rejects any other TTL
  valid_ttls = [60, 300, 900, 1800, 3600, 21600, 43200, 86400, 172800, 259200, 604800, 1209600, 2592000]

  dotname_refer_types = toset(["CNAME", "ALIAS", "NS", "SRV", "MX"])

  records_ext = [for r in var.records : merge(r, {
    type  = upper(r.type)
    host  = r.name == "@" ? "" : r.name
    fqdn  = r.name == "@" ? var.domain : "${r.name}.${var.domain}"
    value = contains(local.dotname_refer_types, upper(r.type)) ? trimsuffix(r.value, ".") : r.value
  }) if !(upper(r.type) == "NS" && r.name == "@")]

  record_map = zipmap([for r in local.records_ext : "${r.type};${r.name};${r.value}"], local.records_ext)

  static_hosts = { for name, record in local.record_map : name => record if !record.dynDns }
  dyndns_hosts = { for r in local.records_ext : "${r.type};${r.name}" => r if r.dynDns && contains(["A", "AAAA"], r.type) }
  # Dynamic TXT records are ACME DNS-01 challenges. Here they become CNAMEs
  # into a zone of their own, which one ClouDNS API sub-user may write.
  acme_hosts = { for r in local.records_ext : r.fqdn => r if r.dynDns && r.type == "TXT" }

  dyndns_value_map = {
    A    = "127.0.0.1"
    AAAA = "::1"
  }
}

locals {
  # ClouDNS drops nameservers inside the zone itself (ns3.foxden.network in
  # foxden.network) when it creates the zone, as their ALIASes don't exist
  # yet. Those become records once the ALIASes do.
  inzone_nameservers  = [for ns in var.nameservers : ns if endswith(ns, ".${var.domain}")]
  outzone_nameservers = [for ns in var.nameservers : ns if !endswith(ns, ".${var.domain}")]
}

resource "cloudns_dns_zone" "domain" {
  domain      = var.domain
  type        = "master"
  nameservers = local.outzone_nameservers

  lifecycle {
    # ClouDNS reports the apex NS records here, in any order and including
    # cloudns_dns_record.apex_ns. Any difference would replace the zone,
    # which deletes every record in it.
    ignore_changes  = [nameservers]
    prevent_destroy = true
  }
}

resource "cloudns_dns_record" "apex_ns" {
  zone     = cloudns_dns_zone.domain.domain
  for_each = toset(local.inzone_nameservers)

  type  = "NS"
  name  = ""
  ttl   = 86400
  value = each.key

  depends_on = [cloudns_dns_record.static]
}

resource "cloudns_dns_record" "static" {
  zone     = cloudns_dns_zone.domain.domain
  for_each = local.static_hosts

  type      = each.value.type
  name      = each.value.host
  ttl       = each.value.ttl
  priority  = each.value.priority
  port      = each.value.port
  weight    = each.value.weight
  value     = each.value.value
  algorithm = each.value.algorithm
  fptype    = each.value.fptype

  lifecycle {
    precondition {
      condition     = contains(local.valid_ttls, each.value.ttl)
      error_message = "ClouDNS does not accept TTL ${each.value.ttl} (${each.value.fqdn} ${each.value.type})."
    }
  }
}

resource "cloudns_dns_record" "acme" {
  zone     = cloudns_dns_zone.domain.domain
  for_each = local.acme_hosts

  type  = "CNAME"
  name  = each.value.host
  ttl   = each.value.ttl
  value = "${each.key}.${var.acme_zones[each.key]}"

  lifecycle {
    precondition {
      condition     = contains(local.valid_ttls, each.value.ttl)
      error_message = "ClouDNS does not accept TTL ${each.value.ttl} (${each.value.fqdn} CNAME)."
    }
  }
}

resource "cloudns_dns_record" "dynamic" {
  zone     = cloudns_dns_zone.domain.domain
  for_each = local.dyndns_hosts

  type  = each.value.type
  name  = each.value.host
  ttl   = each.value.ttl
  value = local.dyndns_value_map[each.value.type]

  lifecycle {
    # The routers keep these up to date
    ignore_changes = [value]
    precondition {
      condition     = contains(local.valid_ttls, each.value.ttl)
      error_message = "ClouDNS does not accept TTL ${each.value.ttl} (${each.value.fqdn} ${each.value.type})."
    }
  }
}

resource "cloudns_dynamic_url" "dynamic" {
  domain   = cloudns_dns_zone.domain.domain
  for_each = local.dyndns_hosts

  recordid = cloudns_dns_record.dynamic[each.key].id
}

locals {
  # The URL is https://ipv4.cloudns.net/api/dynamicURL/?q=<key>. The routers
  # send the key to ipv4.cloudns.net or ipv6.cloudns.net themselves.
  dynamic_keys = { for k, url in cloudns_dynamic_url.dynamic : k => regex("[?&]q=([^&]+)", url.url)[0] }
}

output "zone" {
  value = cloudns_dns_zone.domain.domain
}

output "dynamic_keys" {
  value = { for fqdn in distinct([for r in values(local.dyndns_hosts) : r.fqdn]) : fqdn => {
    ipv4 = one([for k, r in local.dyndns_hosts : local.dynamic_keys[k] if r.fqdn == fqdn && r.type == "A"])
    ipv6 = one([for k, r in local.dyndns_hosts : local.dynamic_keys[k] if r.fqdn == fqdn && r.type == "AAAA"])
    # Host part the routers OR onto their IPv6 prefix
    ipv6_suffix = one([for r in values(local.dyndns_hosts) : r.value if r.fqdn == fqdn && r.type == "AAAA"])
  } }
  sensitive = true
}
