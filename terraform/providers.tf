terraform {
  required_version = "~> 1.10"

  required_providers {
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3.5"
    }
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
    random = {
      source  = "hashicorp/random"
      version = "3.8.1"
    }
    ovh = {
      source  = "ovh/ovh"
      version = "~> 2.11.0"
    }
  }

  backend "s3" {
    bucket = "foxden-tfstate"
    region = "eu-north-1"
    key    = "default.tfstate"
  }
}

provider "aws" {
  region = "eu-west-1"
}
