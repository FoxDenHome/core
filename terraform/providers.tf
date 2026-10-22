terraform {
  required_version = "~> 1.10"

  required_providers {
    external = {
      source  = "hashicorp/external"
      version = "~> 2.4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.1"
    }
    ovh = {
      source  = "ovh/ovh"
      version = "~> 2.23.0"
    }
    fastly = {
      source  = "fastly/fastly"
      version = "~> 10.0.0"
    }
    dns-he-net = {
      source  = "SuperBuker/dns-he-net"
      version = "~> 0.1.1"
    }
  }

  # Connection comes from PG_CONN_STR, set up by tofu.sh
  backend "pg" {}

  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase
    }

    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }

    state {
      method   = method.aes_gcm.state
      enforced = true
    }

    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}

# From state-passphrase.yaml, set up by tofu.sh
variable "state_passphrase" {
  type      = string
  sensitive = true
}

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

provider "dns-he-net" {
  username   = var.he_net_username
  password   = var.he_net_password
  otp_secret = var.he_net_otp_secret
  store_type = "dummy"
}
