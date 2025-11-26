terraform {
  required_version = "~> 1.10"

  required_providers {
    ovh = {
      source  = "ovh/ovh"
      version = "~> 2.9.0"
    }
  }

  backend "s3" {
    bucket = "foxden-tfstate"
    region = "eu-north-1"
    key    = "servers.tfstate"
  }
}
