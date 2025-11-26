data "external" "nix_reverses_json" {
  program = ["${path.module}/nix.sh"]
  query   = {}
}

locals {
  reverses = jsondecode(data.external.nix_reverses_json.result.json)
  ovh_reverses = {
    for ip, reverse in local.reverses["ovh"] :
    ip => {
      subnet  = startswith(ip, "2604:2dc0:500:b") ? "${cidrhost(cidrsubnet("${ip}/128", -72, 0), 0)}/56" : strcontains(ip, ":") ? "${cidrhost(cidrsubnet("${ip}/128", -64, 0), 0)}/64" : "${ip}/32"
      reverse = reverse
    } if !startswith(ip,"10.") && !startswith(ip,"fc") && !startswith(ip,"fd")
  }
}

resource "ovh_ip_reverse" "reverse" {
  for_each                   = local.ovh_reverses
  readiness_timeout_duration = "1m"
  ip_reverse                 = each.key
  ip                         = each.value.subnet
  reverse                    = "${each.value.reverse}."
}
