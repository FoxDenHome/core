locals {
  repositores = {
    spacebuild        = {}
    SpaceAgeModelPack = {}
    Joystick = {
      description = "A joystick module for GMod, originally by NightEagle."
    }
    Falcos-Prop-protection = {
      description = "Falco's prop protection"
    }
    maps         = {}
    multi-parent = {}
    luacheck = {
      description = "A tool for linting and static analysis of Lua code."
    }
    physgun-build-mode = {}
    sbep = {
      description = "Spacebuild Enhancement Pack."
    }
    spacebuild_colliders = {}
    gm_random            = {}
    smartsnap            = {}
    issues               = {}
    GWSockets = {
      default_branch = "master"
    }
    gm_enginespew = {}
    gm_luaerror   = {}
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
