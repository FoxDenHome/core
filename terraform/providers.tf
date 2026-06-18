terraform {
  required_version = "~> 1.10"

  required_providers {
    external = {
      source  = "hashicorp/external"
      version = "~> 2.4.0"
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
