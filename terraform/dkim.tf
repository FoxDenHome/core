data "external" "dkim_json" {
  program = ["${path.module}/dkim.sh"]
  query   = {}
}

resource "cloudns_dns_record" "dkim" {
  for_each = data.external.dkim_json.result

  zone  = module.cloudns_domain[replace(each.key, "/^.*\\._domainkey\\./", "")].zone
  type  = "TXT"
  name  = trimsuffix(each.key, ".${replace(each.key, "/^.*\\._domainkey\\./", "")}")
  ttl   = 3600
  value = each.value
}
