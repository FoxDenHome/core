data "external" "dnssec_json" {
  program = ["${path.module}/dnssec.sh"]
  query   = {
    "domain" = var.domain,
  }
}

locals {
  dnskey_records = toset(jsondecode(data.external.dnssec_json.result.dnskeys))
}

resource "cloudns_dns_record" "dnskey" {
  zone     = cloudns_dns_zone.domain.id
  for_each = { for r in local.dnskey_records : r => split(" ", r) }

  type     = each.value[3]
  name     = trimsuffix(trimsuffix(each.value[0], "${var.domain}."), ".")
  ttl      = tonumber(each.value[1])
  value    = "${each.value[4]} ${each.value[5]} ${each.value[6]} ${each.value[7]}"
}

output "dnskey_records" {
  value = local.dnskey_records
}
