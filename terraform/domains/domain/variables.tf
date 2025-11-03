variable "domain" {
  type = string
}

variable "fastmail" {
  type = bool
}

variable "ses" {
  type = bool
}

variable "vanity_nameserver" {
  type = object({
    name = string
    list = list(string)
  })
  default = null
}

variable "registrar" {
  type    = string
  default = ""
}
