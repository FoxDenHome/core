data "external" "dnssec_json" {
  program = ["${path.module}/dnssec.sh"]
  query   = {
    "domain" = var.domain,
  }
}

output "dnskey_records" {
  value = toset(jsondecode(data.external.dnssec_json.result.dnskeys))
}
