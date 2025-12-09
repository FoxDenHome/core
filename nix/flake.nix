{
  description = "FoxDen NixOS config";

  inputs = {
    # Basics
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    impermanence.url = "github:nix-community/impermanence";
    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Helpers
    flake-utils.url = "github:numtide/flake-utils";

    pyproject-nix.url = "github:pyproject-nix/pyproject.nix";
    pyproject-nix.inputs.nixpkgs.follows = "nixpkgs";

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs = {
        pyproject-nix.follows = "pyproject-nix";
        nixpkgs.follows = "nixpkgs";
      };
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs = {
        pyproject-nix.follows = "pyproject-nix";
        uv2nix.follows = "uv2nix";
        nixpkgs.follows = "nixpkgs";
      };
    };

    # Applications
    backupmgr = {
      url = "git+https://git.foxden.network/FoxDen/backupmgr";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
    carvera-pendant = {
      url = "git+https://git.foxden.network/FoxDen/carvera-pendant";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
    e621dumper = {
      url = "git+https://git.foxden.network/FoxDen/e621dumper";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
    fadumper = {
      url = "git+https://git.foxden.network/FoxDen/fadumper";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
    foxcaves = {
      url = "git+https://git.foxden.network/foxCaves/foxCaves";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
    gitbackup = {
      url = "git+https://git.foxden.network/FoxDen/gitbackup";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
        pyproject-nix.follows = "pyproject-nix";
        uv2nix.follows = "uv2nix";
        pyproject-build-systems.follows = "pyproject-build-systems";
      };
    };
    oauth-jit-radius = {
      url = "git+https://git.foxden.network/FoxDen/oauth-jit-radius";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
    superfan = {
      url = "git+https://git.foxden.network/FoxDen/superfan";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
    systemd-query = {
      url = "git+https://git.foxden.network/FoxDen/systemd-query";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
        pyproject-nix.follows = "pyproject-nix";
        uv2nix.follows = "uv2nix";
        pyproject-build-systems.follows = "pyproject-build-systems";
      };
    };
    tapemgr = {
      url = "git+https://git.foxden.network/FoxDen/tapemgr";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
    uds-proxy = {
      url = "git+https://git.foxden.network/FoxDen/uds-proxy";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };

    spaceage-api = {
      url = "git+https://git.foxden.network/SpaceAge/space_age_api";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
    spaceage-starlord = {
      url = "git+https://git.foxden.network/SpaceAge/StarLord";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
        pyproject-nix.follows = "pyproject-nix";
        uv2nix.follows = "uv2nix";
        pyproject-build-systems.follows = "pyproject-build-systems";
      };
    };
    spaceage-tts = {
      url = "git+https://git.foxden.network/SpaceAge/TTS";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
    spaceage-website = {
      url = "git+https://git.foxden.network/SpaceAge/website";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
    darksignsonline = {
      url = "github:Doridian/DarkSignsOnline";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
  };

  outputs = inputs: import ./outputs.nix inputs;
}
