{ nixpkgs, foxDenLib, ... }:
let
  lib = nixpkgs.lib;
  sshHostsRaw =
    nixosConfigurations:
    lib.attrsets.filterAttrs (name: host: host.ssh == true) (
      foxDenLib.global.config.getAttrSet [ "foxDen" "hosts" "hosts" ] nixosConfigurations
    );
  fixedSshHosts = [
    "router.foxden.network@router.foxden.network"
    "router-backup.foxden.network@router-backup.foxden.network"
  ];
in
{
  sshHostDnsNames =
    nixosConfigurations:
    lib.lists.uniqueStrings (
      fixedSshHosts
      ++ (lib.flatten (
        map (
          host:
          map (
            intf:
            let
              primary = lib.lists.head intf.dns.fqdns;
            in
            (map (fqdn: "${fqdn}@${primary}") intf.dns.fqdns)
          ) (lib.attrsets.attrValues host.interfaces)
        ) (lib.attrsets.attrValues (sshHostsRaw nixosConfigurations))
      ))
    );
}
