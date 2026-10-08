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

  vendorHash = "sha256-4pjL+vHLBHUUh7VolLII9U2tiQVoA+aUoufBrio2H/U=";

  env.CGO_ENABLED = "0";
  ldflags = [
    "-s"
    "-w"
  ];

  meta = {
    description = "FoxDen VPN client daemon, tray applet, device portal and expose edge";
    mainProgram = "foxden-vpn-portal";
  };
}
