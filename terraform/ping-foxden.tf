resource "cloudns_dns_record" "ping_foxden" {
  zone = "foxden.network"

  type  = "CNAME"
  ttl   = 3600
  name  = "ping"
  value = "x.sni.global.fastly.net"
}

output "generated_records" {
  value = {
    "foxden.network" = [for r in setunion([cloudns_dns_record.ping_foxden]) : {
      type     = upper(r.type)
      fqdn     = r.name == "@" ? r.zone : "${r.name}.${r.zone}"
      name     = r.name
      ttl      = r.ttl
      value    = r.value
      critical = false
      horizon  = "*"
    }]
  }
}
