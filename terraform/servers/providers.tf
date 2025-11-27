terraform {
  required_version = "~> 1.10"

  required_providers {
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3.5"
    }
    ovh = {
      source  = "ovh/ovh"
      version = "~> 2.10.0"
    }
  }

  backend "s3" {
    bucket = "foxden-tfstate"
    region = "eu-north-1"
    key    = "servers.tfstate"
  }
}
