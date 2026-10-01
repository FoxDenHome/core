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

  vendorHash = "sha256-PzRD2qCm9b/phLjT0RX8l0rXMj0fIHqL9C8xHnU2SBI=";

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
