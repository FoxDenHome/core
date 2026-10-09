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

  vendorHash = lib.trim (builtins.readFile ../../../vpn/vendor-hash.txt);

  env.CGO_ENABLED = "0";
  # The tray is `foxden-vpnd tray`; the link keeps the old name working.
  postInstall = ''
    ln -s foxden-vpnd $out/bin/foxden-vpn-tray
  '';
  ldflags = [
    "-s"
    "-w"
  ];

  meta = {
    description = "FoxDen VPN client daemon and tray applet, device portal and expose edge";
    mainProgram = "foxden-vpn-portal";
  };
}
