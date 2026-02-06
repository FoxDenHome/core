inputs@{
  nixpkgs,
  home-manager,
  self,
  ...
}:
let
  isNixFile =
    path: nixpkgs.lib.filesystem.pathIsRegularFile path && nixpkgs.lib.strings.hasSuffix ".nix" path;

  mkRelPath = (
    root: path: nixpkgs.lib.strings.removePrefix (builtins.toString root + "/") (builtins.toString path)
  );

  mkModuleList = (
    dir: (nixpkgs.lib.filter isNixFile (nixpkgs.lib.filesystem.listFilesRecursive dir))
  );

  allLibs = {
    inherit foxDenLib;
    flakeInputs = inputs;
    hostSystem = builtins.currentSystem;
  }
  // (nixpkgs.lib.filterAttrs (name: value: name != "self") inputs);

  tryEvalOrEmpty = (
    val:
    let
      eval = (builtins.tryEval val);
    in
    if eval.success then eval.value else { }
  );

  mkModuleAttrSet = (
    dir:
    let
      loadedMods = map (
        path:
        let
          nameRaw = nixpkgs.lib.strings.removeSuffix ".nix" (mkRelPath dir path);
        in
        {
          name = nixpkgs.lib.strings.removeSuffix "/main" nameRaw;
          value = import path allLibs;
        }
      ) (mkModuleList dir);
    in
    {
      nested = (
        nixpkgs.lib.attrsets.updateManyAttrsByPath (map (
          { name, value }:
          {
            path = (nixpkgs.lib.strings.splitString "/" name);
            update = old: (tryEvalOrEmpty old) // value;
          }
        ) loadedMods) { }
      );

      flat = nixpkgs.lib.attrsets.listToAttrs loadedMods;
    }
  );

  foxDenLibsRaw = mkModuleAttrSet ./modules/lib;
  foxDenLib = foxDenLibsRaw.nested;

  modules =
    (mkModuleList ./modules/nixos)
    ++ (nixpkgs.lib.filter (mod: mod != null) (
      map (mod: mod.nixosModule or null) (nixpkgs.lib.attrsets.attrValues foxDenLibsRaw.flat)
    ));

  systemModules = mkModuleList ./systems;
  systemInfos = map (
    path:
    let
      relPath = mkRelPath ./systems path;
      splitPath = nixpkgs.lib.strings.splitString "/" relPath;
    in
    rec {
      system = builtins.elemAt splitPath 0;
      name = builtins.elemAt splitPath 1;
      path = "${system}/${name}/";
    }
  ) systemModules;

  systems = map (info: {
    inherit (info) name system;
    modules = nixpkgs.lib.filter (
      mod:
      let
        relPath = mkRelPath ./systems mod;
      in
      nixpkgs.lib.strings.hasPrefix info.path relPath
    ) systemModules;
  }) systemInfos;

  ipReverses = foxDenLib.global.hosts.getIPReverses nixosConfigurations;
  dns = foxDenLib.global.dns.mkConfig nixosConfigurations;
  dhcp = foxDenLib.global.dhcp.make nixosConfigurations;
  firewall = foxDenLib.global.firewall.make nixosConfigurations;
  haproxy = foxDenLib.global.haproxy.make nixosConfigurations;
  kanidm = foxDenLib.global.kanidm.mkConfig nixosConfigurations;
  sshHostDnsNames = foxDenLib.global.ssh.sshHostDnsNames nixosConfigurations;

  mkSystemConfig = system: {
    name = system.name;
    value = nixpkgs.lib.nixosSystem {
      specialArgs = allLibs // {
        systemArch = system.system;
        hostName = system.name;
        inherit
          dhcp
          firewall
          haproxy
          kanidm
          dns
          ipReverses
          ;
      };
      modules = [
        (
          { ... }:
          {
            config.networking.hostName = system.name;
            config.sops.defaultSopsFile = ./secrets/${system.name}.yaml;
          }
        )
      ]
      ++ system.modules
      ++ modules;
    };
  };

  mkNetboot =
    arch:
    nixpkgs.lib.nixosSystem {
      system = "${arch}-linux";
      modules = [
        (
          {
            config,
            pkgs,
            modulesPath,
            ...
          }:
          let
            homeCfg =
              { ... }:
              {
                home.stateVersion = config.system.nixos.release;
                home.file = {
                  ".config/nixpkgs/config.nix" = {
                    enable = true;
                    force = true;
                    text = "{ allowUnfree = true; }";
                  };
                };
              };
          in
          {
            imports = [
              "${modulesPath}/installer/netboot/netboot-minimal.nix"
              home-manager.nixosModules.home-manager
            ];
            config = {
              system.stateVersion = config.system.nixos.release;
              nixpkgs = {
                localSystem.system = "x86_64-linux"; # TODO: This is annoying, but builtins.currentSystem is no more
                crossSystem.system = "${arch}-linux";
                config.allowUnfree = true;
              };
              nix.settings.experimental-features = [
                "nix-command"
                "flakes"
              ];
              environment.systemPackages = with pkgs; [
                arch-install-scripts
                git
                htop
                nano
                pacman
                rsync
                screen
              ];
              boot.uki.settings.UKI.Initrd =
                "${config.system.build.netbootRamdisk}/${config.system.boot.loader.initrdFile}";
              home-manager.users = {
                root = homeCfg;
                nixos = homeCfg;
              };
              home-manager.useGlobalPkgs = true;
            };
          }
        )
      ];
    };

  nixosConfigurations = (nixpkgs.lib.attrsets.listToAttrs (map mkSystemConfig systems)) // {
    "x86_64-netboot" = mkNetboot "x86_64";
    "aarch64-netboot" = mkNetboot "aarch64";
  };
in
{
  nixosConfigurations = nixosConfigurations;

  dns = {
    attrset = dns;
    json = builtins.toFile "dns.json" (builtins.toJSON dns);
  };
  ipReverses = {
    attrset = ipReverses;
    json = builtins.toFile "ipReverses.json" (builtins.toJSON ipReverses);
  };
  sshHostDnsNames = {
    attrset = sshHostDnsNames;
    json = builtins.toFile "sshHostDnsNames.json" (builtins.toJSON sshHostDnsNames);
  };
  haproxy = {
    source = haproxy;
    text = nixpkgs.lib.attrsets.mapAttrs (name: cfg: builtins.toFile "haproxy.cfg" cfg) haproxy;
  };
  dhcp = {
    attrset = dhcp;
    json = nixpkgs.lib.attrsets.mapAttrs (
      name: cfg: builtins.toFile "dhcp.json" (builtins.toJSON cfg)
    ) dhcp;
  };
  firewall = {
    attrset = firewall;
    json = nixpkgs.lib.attrsets.mapAttrs (
      name: cfg: builtins.toFile "firewall.json" (builtins.toJSON cfg)
    ) firewall;
  };

  foxDenLib = foxDenLib;
  self = self;
}
