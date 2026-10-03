{ foxDenLib, nixpkgs, ... }:
let
  lib = nixpkgs.lib;

  firstFQDN =
    host:
    lib.findFirst (x: x != null) null (
      map (iface: lib.head (iface.dns.fqdns ++ [ null ])) (lib.attrValues host.interfaces)
    );

  entry =
    name: host:
    let
      ssh = if host.ssh then firstFQDN host else null;
      inherit (host.launcher) webUI kvm;
    in
    lib.filterAttrs (_: v: v != null) {
      inherit name ssh;
      web =
        if webUI.url != null then
          {
            inherit (webUI) url radius;
          }
        else
          null;
      kvm =
        if kvm.host != null && kvm.port != null then
          {
            inherit (kvm) host port;
          }
        else
          null;
    };
  # Not foxDen hosts; the routers are also in ssh.nix.
  fixedHosts = [
    {
      name = "router";
      ssh = "router.foxden.network";
    }
    {
      name = "router-backup";
      ssh = "router-backup.foxden.network";
    }
    {
      name = "ntpi";
      kvm = {
        host = "kvm-rack.foxden.network";
        port = 3;
      };
    }
  ];
in
{
  # What the VPN tray's Servers menu offers: SSH, web UIs and KVM consoles,
  # by host name.
  mkConfig = nixosConfigurations: {
    hosts =
      fixedHosts
      ++ lib.filter (e: e ? ssh || e ? web || e ? kvm) (
        lib.mapAttrsToList entry (foxDenLib.global.hosts.getHosts nixosConfigurations)
      );
  };
}
