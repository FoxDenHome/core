locals {
  repositores = {
    sharex = {
      description  = "ShareX config files"
      homepage_url = "https://foxcav.es"
    }
    raven-lua = {
      description = "A Lua interface to Sentry"
    }
    lua-resty-cookie = {
      description = "Lua library for HTTP cookie manipulations for OpenResty/ngx_lua"
    }
    lua-resty-aws-signature = {
      description = "AWS signature V4 library for OpenResty + Lua"
    }

    lua-gd = {
      description  = "Lua bindings to the LibGD"
      homepage_url = "https://ittner.github.com/lua-gd"
    }
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
