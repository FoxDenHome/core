locals {
  archived_repositores = {
    foxCaves = {
      description      = "Moved to https://git.foxden.network/foxCaves/foxCaves"
    }
    lua-resty-auto-ssl    = {},
    base-image            = {},
    FoxScreen             = {},
    LEGACY_foxCavesChrome = {},
    LEGACY_foxScreen      = {},
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
