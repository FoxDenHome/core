data "external" "dnssec_json" {
  program = ["${path.module}/dnssec.sh"]
  query = {
    "domain" = var.domain,
  }
}

locals {
  dnskey_records = { for record in(jsondecode(data.external.dnssec_json.result.dnskeys)) :
    split("|", record)[1] => {
      source = split("|", record)[0]
    }
  }
}

output "dnskey_records" {
  value = local.dnskey_records
}
