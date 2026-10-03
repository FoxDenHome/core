{ lib, pkgs, ... }:
pkgs.buildGoModule {
  pname = "foxden-vpn";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../../../vpn;
    fileset = lib.fileset.unions [
      ../../../vpn/go.mod
      ../../../vpn/go.sum
      ../../../vpn/cmd
      ../../../vpn/internal
    ];
  };

  vendorHash = "sha256-/zoJJ1R+2Aci+Hazz6PvGnmR+lTG2p5qLAMFHmvmNrQ=";

  env.CGO_ENABLED = "0";
  ldflags = [
    "-s"
    "-w"
  ];

  meta = {
    description = "FoxDen VPN client daemon, tray applet and device portal";
    mainProgram = "foxden-vpn-portal";
  };
}
