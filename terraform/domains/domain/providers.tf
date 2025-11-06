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
      source = "SuperBuker/dns-he-net"
      version = "0.1.0"
    }
  }
}
