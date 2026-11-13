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
      version = "~> 2.24.0"
    }
    fastly = {
      source  = "fastly/fastly"
      version = "~> 10.2.0"
    }
    cloudns = {
      source  = "ClouDNS/cloudns"
      version = "~> 1.3"
    }
  }

  # Connection comes from PG_CONN_STR, set up by tf.sh
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

# From state-passphrase.yaml, set up by tf.sh
variable "state_passphrase" {
  type      = string
  sensitive = true
}

provider "cloudns" {}
