locals {
  archived_repositores = {
    docker          = {}
    SpaceAgeCentral = {}
    SpaceAge_Old_Archive = {
      visibility = "private",
    }
    ansible = {
      visibility        = "private"
      branch_protection = false
    }
    website = {
      description = "Moved to https://git.foxden.network/SpaceAge/website"
    }
    StarLord = {
      description = "Moved to https://git.foxden.network/SpaceAge/StarLord"
    }
    TTS = {
      description = "Moved to https://git.foxden.network/SpaceAge/TTS"
    }
    space_age_api = {
      description = "Moved to https://git.foxden.network/SpaceAge/space_age_api"
    }
    SpaceAge = {
      description = "Moved to https://git.foxden.network/SpaceAge/SpaceAge"
    }
  }
}

module "archived_repo" {
  source = "../modules/repo/archived"

  for_each = local.archived_repositores

  repository = merge({
    name = each.key

    visibility = "public"
  }, each.value)
}
