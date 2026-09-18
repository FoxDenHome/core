{
  lib,
  pkgs,
  config,
  foxDenLib,
  ...
}:
let
  eSA = lib.strings.escapeShellArg;
  wireguardType =
    with lib.types;
    submodule {
      options = {
        host = lib.mkOption {
          type = str;
        };
        interface = lib.mkOption {
          type = attrsOf anything;
        };
      };
    };

  svcConfig = config.foxDen.services.wireguard;
in
{
  options.foxDen.services.wireguard =
    with lib.types;
    lib.mkOption {
      type = attrsOf wireguardType;
      default = { };
    };

  config.environment.persistence."/nix/persist/wireguard" = {
    hideMounts = true;
    directories = [
      {
        directory = "/var/lib/wireguard";
        mode = "u=rwx,g=,o=";
      }
    ];
  };

  config.networking.wireguard.interfaces = lib.attrsets.mapAttrs (
    name:
    { host, interface, ... }:
    let
      hostCfg = foxDenLib.hosts.getByName config host;
    in
    lib.mkMerge [
      {
        mtu = lib.mkDefault 1280;
        interfaceNamespace = if host != "" then hostCfg.namespace else null;
        generatePrivateKeyFile = true;
        privateKeyFile = "/var/lib/wireguard/${name}.key";
      }
      interface
    ]
  ) svcConfig;

  config.systemd.services =
    let
      ipCmd = eSA "${pkgs.iproute2}/bin/ip";

      # Tunnels that live inside a netns of ours, grouped by the host owning it.
      inNetns = lib.attrsets.filterAttrs (
        name: value: value.host != "" && (foxDenLib.hosts.getByName config value.host).namespace != null
      ) svcConfig;
    in
    lib.mkMerge [
      (lib.attrsets.listToAttrs (
        map (
          { name, value }:
          let
            hostCfg = foxDenLib.hosts.getByName config value.host;
          in
          {
            name = "wireguard-${name}";
            value =
              if value.host == "" then
                { }
              else
                {
                  requires = [ hostCfg.unit ];
                  bindsTo = [ hostCfg.unit ];
                  after = [ hostCfg.unit ];
                };
          }
        ) (lib.attrsets.attrsToList svcConfig)
      ))

      (lib.attrsets.mapAttrs' (
        hostName: entries:
        let
          hostCfg = foxDenLib.hosts.getByName config hostName;
        in
        {
          name = lib.strings.removeSuffix ".service" hostCfg.unit;
          value.serviceConfig.ExecStop = lib.mkBefore (
            map (
              { name, ... }: "-${ipCmd} netns exec ${eSA hostCfg.namespace} ${ipCmd} link del dev ${eSA name}"
            ) entries
          );
        }
      ) (lib.lists.groupBy (entry: entry.value.host) (lib.attrsets.attrsToList inNetns)))
    ];
}
