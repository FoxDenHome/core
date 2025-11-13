terraform {
  required_version = "~> 1.10.0"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket = "foxden-tfstate"
    region = "eu-north-1"
    key    = "github-foxdenhome.tfstate"
  }
}

provider "github" {
  owner = "FoxDenHome"
}
