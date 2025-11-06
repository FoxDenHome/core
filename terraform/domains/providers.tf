terraform {
  required_providers {
    cloudns = {
      source  = "ClouDNS/cloudns"
      version = "~> 1.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    dns = {
      source  = "hashicorp/dns"
      version = "~> 3.2"
    }
    dns-he-net = {
      source  = "SuperBuker/dns-he-net"
      version = "0.1.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
  }

  backend "s3" {
    bucket = "foxden-tfstate"
    region = "eu-north-1"
    key    = "domains.tfstate"
  }
}

provider "aws" {
  region = "eu-west-1"
}

provider "dns-he-net" {
  username   = var.he_net_username
  password   = var.he_net_password
  otp_secret = var.he_net_otp_secret
  store_type = "encrypted"
}
