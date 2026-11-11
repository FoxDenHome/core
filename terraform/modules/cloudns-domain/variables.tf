variable "domain" {
  type = string
}

# ClouDNS makes these the zone's apex NS records when it creates the zone.
# Changing them replaces the zone, and the apex NS records from nix are not
# managed as records.
variable "nameservers" {
  type = list(string)
}

# _acme-challenge.<name> => ClouDNS zone that challenge is CNAMEd into
variable "acme_zones" {
  type = map(string)
}

variable "records" {
  type = list(object({
    dynDns    = optional(bool, false)
    name      = string
    ttl       = number
    type      = string
    value     = string
    priority  = optional(number)
    port      = optional(number)
    weight    = optional(number)
    algorithm = optional(number)
    fptype    = optional(number)
  }))
}
