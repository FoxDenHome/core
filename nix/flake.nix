{
  description = "FoxDen NixOS config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/0b4defa2584313f3b781240b29d61f6f9f7e0df3";

    impermanence.url = "github:nix-community/impermanence";
    lanzaboote.url = "github:nix-community/lanzaboote";
    lanzaboote.inputs.nixpkgs.follows = "nixpkgs";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    backupmgr.url = "git+https://git.foxden.network/FoxDen/backupmgr";
    backupmgr.inputs.nixpkgs.follows = "nixpkgs";
    carvera-pendant.url = "git+https://git.foxden.network/FoxDen/carvera-pendant";
    carvera-pendant.inputs.nixpkgs.follows = "nixpkgs";
    e621dumper.url = "git+https://git.foxden.network/FoxDen/e621dumper";
    e621dumper.inputs.nixpkgs.follows = "nixpkgs";
    fadumper.url = "git+https://git.foxden.network/FoxDen/fadumper";
    fadumper.inputs.nixpkgs.follows = "nixpkgs";
    gitbackup.url = "git+https://git.foxden.network/FoxDen/gitbackup";
    gitbackup.inputs.nixpkgs.follows = "nixpkgs";
    oauth-jit-radius.url = "git+https://git.foxden.network/FoxDen/oauth-jit-radius";
    oauth-jit-radius.inputs.nixpkgs.follows = "nixpkgs";
    superfan.url = "git+https://git.foxden.network/FoxDen/superfan";
    superfan.inputs.nixpkgs.follows = "nixpkgs";
    systemd-query.url = "git+https://git.foxden.network/FoxDen/systemd-query";
    systemd-query.inputs.nixpkgs.follows = "nixpkgs";
    tapemgr.url = "git+https://git.foxden.network/FoxDen/tapemgr";
    tapemgr.inputs.nixpkgs.follows = "nixpkgs";
    uds-proxy.url = "git+https://git.foxden.network/FoxDen/uds-proxy";
    uds-proxy.inputs.nixpkgs.follows = "nixpkgs";

    spaceage-api.url = "github:SpaceAgeMP/space_age_api";
    spaceage-api.inputs.nixpkgs.follows = "nixpkgs";
    spaceage-starlord.url = "github:SpaceAgeMP/StarLord";
    spaceage-starlord.inputs.nixpkgs.follows = "nixpkgs";
    spaceage-tts.url = "github:SpaceAgeMP/TTS";
    spaceage-tts.inputs.nixpkgs.follows = "nixpkgs";
    spaceage-website.url = "github:SpaceAgeMP/website";
  };

  outputs = inputs: import ./outputs.nix inputs;
}
