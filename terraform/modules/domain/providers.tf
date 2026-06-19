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
    dns = {
      source  = "hashicorp/dns"
      version = "~> 3.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.0"
    }
    dns-he-net = {
      source  = "SuperBuker/dns-he-net"
      version = "~> 0.1.1"
    }
  }
}
