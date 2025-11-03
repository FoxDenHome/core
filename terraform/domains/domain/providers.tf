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
  }
}
