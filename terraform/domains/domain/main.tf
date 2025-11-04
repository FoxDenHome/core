resource "cloudns_dns_zone" "domain" {
  domain = var.domain
  type   = "master"
}
