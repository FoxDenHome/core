data "external" "dnssec_json" {
  program = ["${path.module}/dnssec.sh"]
  query   = {
    "domain" = var.domain,
  }
}

locals {
  dnskey_records = toset(jsondecode(data.external.dnssec_json.result.dnskeys))
}

output "dnskey_records" {
  value = local.dnskey_records
}
