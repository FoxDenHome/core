{ nixpkgs, foxDenLib, ... }:
let
  lib = nixpkgs.lib;
  sshHostsRaw =
    nixosConfigurations:
    lib.attrsets.filterAttrs (name: host: host.ssh == true) (
      foxDenLib.global.config.getAttrSet [ "foxDen" "hosts" "hosts" ] nixosConfigurations
    );
in
{
  sshHostDnsNames =
    nixosConfigurations:
    lib.lists.uniqueStrings (
      lib.flatten (
        map (host: map (intf: intf.dns.fqdn) (lib.attrsets.attrValues host.interfaces)) (
          lib.attrsets.attrValues (sshHostsRaw nixosConfigurations)
        )
      )
    );
}
