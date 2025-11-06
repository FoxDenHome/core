variable "he_net_username" {
  type = string
}

variable "he_net_password" {
  type      = string
  sensitive = true
}

variable "he_net_otp_secret" {
  type      = string
  sensitive = true
}
