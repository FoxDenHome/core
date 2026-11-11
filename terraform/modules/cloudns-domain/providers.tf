terraform {
  required_version = "~> 1.10"
  required_providers {
    cloudns = {
      source  = "ClouDNS/cloudns"
      version = "~> 1.3"
    }
  }
}
