{ nixpkgs, foxDenLib, ... }:
let
  lib = nixpkgs.lib;
  sshHostsRaw = nixosConfigurations: lib.attrsets.filterAttrs (name: host: host.ssh == true) (foxDenLib.global.config.getAttrSet [ "foxDen" "hosts" "hosts" ] nixosConfigurations);
in
{
  # TODO: Go back to uniqueStrings once next NixOS stable
  sshHostDnsNames = nixosConfigurations:
    lib.lists.unique (
      lib.flatten
        (map (host:
          map (intf: intf.dns.name) (lib.attrsets.attrValues host.interfaces))
        (lib.attrsets.attrValues (sshHostsRaw nixosConfigurations))));
}
