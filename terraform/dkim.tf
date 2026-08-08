data "external" "dkim_json" {
  program = ["${path.module}/dkim.sh"]
  query   = {}
}

resource "dns-he-net_txt" "dkim" {
  zone_id  = local.he_zone_ids[replace(each.key, "/^.*\\._domainkey\\./", "")]
  for_each = data.external.dkim_json.result

  domain = each.key
  ttl    = 3600
  data   = "\"${each.value}\""
}
