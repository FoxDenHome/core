locals {
  archived_repositores = {
    AmplifiLink          = {},
    CoreLogic            = {},
    CorsairLinkPlusPlus  = {},
    DracoChat            = {},
    FoxEEEControl        = {},
    FoxdenNetworkScripts = {},
    FoxyMC_Classic       = {},
    GCodeWebGL           = {},
    HackCPU              = {},
    HackmudIRC           = {},
    JumpAndRoll          = {},
    KeyboardControl      = {},
    QuickRecovery        = {},
    SPAuthProxy          = {},
    SPMisc               = {},
    SSLChainLib          = {},
    SSLChainWeb          = {},
    ShaderBox            = {},
    ShaderDemo           = {},
    SteamMobileLib       = {},
    XVManageNode         = {},
    XVManagePanel        = {},
    Yiffcraft            = {},
    bcachefs-scripts     = {},
    cfworker-doh         = {},
    channeler            = {},
    chat-finder = {
      visibility = "private",
    },
    docker-minico2           = {},
    docker-pihole            = {},
    docker-seafile           = {},
    evldns                   = {},
    fhem-InfluxDBLog         = {},
    gitrunner                = {},
    hashtopolis-agent-python = {},
    jumpme                   = {},
    ledbadge                 = {},
    ledmgr                   = {},
    mikronode                = {},
    minit                    = {},
    netgen                   = {},
    netmap                   = {},
    nettest                  = {},
    node-dnsd                = {},
    node-mount               = {},
    node-unshare             = {},
    ntp-clock-projector      = {},
    opendkame                = {},
    pingshell                = {},
    presencegetter           = {},
    puppeteer-page-proxy     = {},
    rfcat-mqtt               = {},
    sdr-misc                 = {},
    slow-uboot-flasher       = {},
    tesla-proxy              = {},
    tetris-os                = {},
    tuya-prometheus          = {},
    vfmgr                    = {},
    wireworld_cuda           = {},
    BambuSource2Raw = {
      description = "Get raw webcam stream of BambuLabX1 3D printer"
    }
    NoTouchScreenFirmware = {
      description = "Stripped down version of BIGTREETECH-TouchScreenFirmware which only supports ST7920 emulation (Marlin Mode)"
    }
    RigolLib = {
      description = ".NET Interface for Rigol devices (currently Oscilloscopes)"
    }
    TeslaLogger  = {}
    healthcheckd = {}
    j4210u-app   = {}
    rd60xx       = {}
    sdparm = {
      description = "Fork of the official git-svn mirror for sdparm, access SCSI parameters (mode+VPD pages)"
    }
    floppy-linux           = {}
    mister-linux           = {}
    tiny-floppy-bootloader = {}
    MCAdmin                = {}

    G4-Doorbell-Pro-Max = {}
    apt-mirror-docker = {
      description = "Up to date apt-mirror script, containerized for mirroring + serving."
    }
    picotcp = {
      description = "PicoTCP is a free TCP/IP stack implementation"
    }
    dnsmasq-docker = {}
    pdns-static    = {}
    pikvm-notes    = {}
    terraform-provider-hexonet = {
      description = "Terraform provider for Hexonet API"
    }

    quictun = {}
    qcat = {
      description = "Minimal version of netcat that runs over QUIC with ephemeral randomly generated passwords to authenticate the connection."
    }

    Uplink = {
      visibility     = "private"
      default_branch = "trunk"
    }
    DEFCON = {
      visibility     = "private"
      default_branch = "trunk"
    }
    DarwiniaAndMultiwinia = {
      visibility     = "private"
      default_branch = "trunk"
    }

    website = {}
    LuaJIT = {
      description = "Mirror of the LuaJIT git repository"
    }
    fakerfs = {
      description = "FUSE filesystem that can overlay fake files on top of a real filesystem"
    }
    Joybus-PIO         = {}
    hak5-wifi-coconut  = {}
    deffs              = {}
    fakeuinput         = {}
    homebrew-tap       = {}
    hammerspoon-config = {}
    MuxyProxy = {
      description = "Multi-Protocol reverse proxy detecting a client's protocol intelligently for dynamic forwarding"
    }
    os-config = {
      description = "Various OS configuration/customization files"
    }
    libMSRx05          = {}
    hashtopolis-docker = {}
    factorio-docker = {
      description = "Factorio headless server in a Docker container"
    }
    dockerheal = {}
    foxTorrent = {}
    GM67 = {
      description = "RP2040 code and Python library for interacting with GROW GM67 barcode scanner"
    }
    fox             = {}
    linuxptp-client = {}
    mscob = {
      description = "GNUCobol implementation of MSNP :3"
    }
    UKWeaponTris = {}
    unsaflok = {
      visibility = "private"
    }
    sevenroom-scraper = {
      description = "I really like food."
    }
    meshtastic-firmware = {
      description  = "Firmware for Meshtastic devices"
      homepage_url = "https://meshtastic.org"
    }
    foxDNS = {
      description = "DNS server written in Golang"
    }
    foxIngress = {
      description = "HTTP(S)/QUIC SNI/Host router"
    }
    depthy           = {}
    fbsplash         = {}
    linux-fbcondecor = {}
    miscsplashutils  = {}
    plenopticam      = {}
    flippertools = {
      visibility = "private"
    }
    panon = {
      description    = "An Audio Visualizer Widget in KDE Plasma (works in KDE Plasma 6)"
      default_branch = "6.x.x"
    }
    panon-effects = {}

    fadumper = {
      description = "Moved to https://git.foxden.network/FoxDen/fadumper"
    }
    gitbackup = {
      description = "Moved to https://git.foxden.network/FoxDen/gitbackup"
    }
    oauth-jit-radius = {
      description = "Moved to https://git.foxden.network/FoxDen/oauth-jit-radius"
    }
    superfan = {
      description = "Moved to https://git.foxden.network/FoxDen/superfan"
    }
    uds-proxy = {
      description = "Moved to https://git.foxden.network/FoxDen/uds-proxy"
    }
    aurbuild = {
      description = "Moved to https://git.foxden.network/FoxDen/aurbuild"
    }
    peercred = {
      description = "Moved to https://git.foxden.network/FoxDen/peercred"
    }
  }
}

# function tfimparc -a repo; tofu import "module.archived_repo[\"$repo\"].github_repository.repo" "$repo"; end
# function tfarc -a repo; tofu state mv "module.repo[\"$repo\"]" "module.archived_repo[\"$repo\"]"; end

module "archived_repo" {
  source = "../modules/repo/archived"

  for_each = local.archived_repositores

  repository = merge({
    name = each.key

    visibility = "public"
  }, each.value)
}
