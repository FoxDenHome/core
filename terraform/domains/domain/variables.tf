variable "domain" {
  type = string
}

variable "ses" {
  type = bool
}

variable "nameservers" {
  type    = set(string)
  default = null
}

variable "registrar" {
  type    = string
  default = ""
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
