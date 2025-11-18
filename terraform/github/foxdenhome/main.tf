locals {
  repositores = {
    nodered = {
      branch_protection = false
      visibility        = "private"
    }
    homeassistant = {
      branch_protection = false
      visibility        = "private"
    }
    NixieClockDori = {}
    CC1101Duino      = {}
    ntpi             = {}
    shutdownd        = {}
    keepass-unlocker = {}
    core                   = {
      description = "Mirror of https://git.foxden.network/FoxDen/core"
    }
    foxden-radius-autofill = {}
    goscsi                 = {}
    initcpio-uki-sbsign    = {}
  }

  members = {
    Doridian    = "admin",
    SimonSchick = "admin",
  }
}

module "repo" {
  for_each = local.repositores

  source = "../modules/repo"
  repository = merge({
    name         = each.key
    description  = ""
    homepage_url = ""

    visibility = "public"

    required_checks   = []
    branch_protection = true

    pages = null
  }, each.value)
}

resource "github_membership" "members" {
  for_each = local.members

  username = each.key
  role     = each.value
}
