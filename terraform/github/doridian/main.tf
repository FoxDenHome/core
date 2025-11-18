locals {
  repositores = {
    wsvpn = {
      description = "VPN over WebSocket and WebTransport"
      required_checks = [
        "lint (macos-latest)",
        "lint (ubuntu-latest)",
        "lint (windows-latest)",
        "test (macos-latest)",
        "test (ubuntu-latest)",
      ]
    }
    water = {
      description = "A simple TUN/TAP library written in native Go."
      required_checks = [
        "lint (macos-latest)",
        "lint (ubuntu-latest)",
        "lint (windows-latest)",
        "test (macos-latest)",
        "test (ubuntu-latest)",
      ]
    }
    jsip-wsvpn        = {}
    wsvpn-js          = {}
    query-finder      = {}
    factorio-fox-todo = {}
    factorio-pause-commands = {
      description       = "Factorio mod to add pause and unpause commands"
      branch_protection = false
    }
    slimfat    = {}
    tracething = {}
    jsip = {
      description = "TCP/UDP/ICMP/IP/Ethernet stack in pure TypeScript."
    }
    LuaJS = {
      description = "Lua VM running in Javascript (using emscripten)"
    }
    HomeAssistantMQTT = {}
    streamdeckpi      = {}
    go-streamdeck     = {}
    go-haws           = {}
    BambuProfiles = {
      description = "Profiles for Bambu Lab printers"
    }
    OpenBambuAPI = {
      description = "Bambu API docs"
    }
    # Forks
    qmk_firmware = {
      description       = "Open-source keyboard firmware for Atmel AVR and Arm USB families"
      branch_protection = false
    }
    gopacket = {
      description       = "Provides packet processing capabilities for Go"
      branch_protection = false
    }
    carvera-pendant = {
      description = "Mirror of https://git.foxden.network/FoxDen/carvera-pendant"
    }
    karalabe_hid = {
      description = "Gopher Interface Devices (USB HID)"
    }
    DarkSignsOnline = {
      homepage_url = "https://darksignsonline.com"
    }
    NetDAQ = {}
    fwui = {
      description = "Framework 16 LED matrix UI for expansion card status"
    }
    kbidle = {}
    node-single-instance = {
      description = "Check if an instance of the current application is running or not."
    }
    qmk_hid = {
      description = "Commandline tool for interacting with QMK devices over HID"
    }
    ustreamer = {
      description  = "µStreamer - Lightweight and fast MJPEG-HTTP streamer"
      homepage_url = "https://pikvm.org"
    }
    viauled = {}
    inputmodule-rs = {
      description = "Framework Laptop 16 Input Module SW/FW"
    }
    dotfiles                    = {}
    libnss_igshim               = {}
    linux-cachyos-dori = {
      description       = "CachyOS kernel with my own patches :3"
      branch_protection = false
    }

    python-ax1200i = {}
    tanqua         = {}

    DroneControl = {
      visibility = "private"
    }

    froxlor-system = {}

    kanidm = {
      description    = "Kanidm: A simple, secure and fast identity management platform"
      default_branch = "master"
    }
  }
}

# function tfimp -a repo; tofu import "module.repo[\"$repo\"].github_repository.repo" "$repo"; tofu import "module.repo[\"$repo\"].github_branch_protection.main[0]" "$repo:main"; end

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
