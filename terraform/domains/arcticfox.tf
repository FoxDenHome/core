locals {
  doridian_net_zone = module.domain["doridian.net"].zone
}

module "arcticfox_ses" {
  source = "./domain/ses"

  zone      = local.doridian_net_zone
  domain    = "doridian.net"
  subdomain = "arcticfox"
}
