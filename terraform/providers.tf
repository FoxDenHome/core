terraform {
  required_version = "~> 1.10"

  required_providers {
    external = {
      source  = "hashicorp/external"
      version = "~> 2.4.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.0"
    }
    ovh = {
      source  = "ovh/ovh"
      version = "~> 2.14.0"
    }
    fastly = {
      source  = "fastly/fastly"
      version = "~> 9.3.0"
    }
    dns-he-net = {
      source  = "SuperBuker/dns-he-net"
      version = "~> 0.1.1"
    }
  }

  backend "local" {
    path = "default.tfstate"
  }
}

provider "aws" {
  region = "eu-west-1"
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
}
