variable "domain" {
  type = string
}

variable "zone" {
  type = string
}

variable "subdomain" {
  type = string
}

variable "mail_from_subdomain" {
  type    = string
  default = "ses-bounce"
}
