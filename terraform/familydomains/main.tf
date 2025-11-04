locals {
  domains = {
    "candy-girl.net" = {
      registrar = "aws",
    },
    "zoofaeth.de" = {
      registrar = "inwx",
    },
  }
}

module "records" {
  for_each = local.domains
  source   = "./records"

  zone   = module.domain[each.key].zone
  domain = each.key
}

module "domain" {
  for_each = local.domains
  source   = "../modules/domain"

  domain    = each.key
  ses       = true
  registrar = each.value.registrar
}
