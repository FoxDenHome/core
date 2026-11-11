{ lib, pkgs, ... }:
pkgs.buildGoModule {
  pname = "packetfox";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../../../packetfox;
    fileset = lib.fileset.unions [
      ../../../packetfox/go.mod
      ../../../packetfox/go.sum
      ../../../packetfox/cmd
      ../../../packetfox/internal
    ];
  };

  vendorHash = lib.trim (builtins.readFile ../../../packetfox/vendor-hash.txt);

  env.CGO_ENABLED = "0";
  ldflags = [
    "-s"
    "-w"
    # pfox-agent runs with capabilities, so it must not look tcpdump up in PATH
    "-X main.tcpdumpPath=${pkgs.tcpdump}/bin/tcpdump"
  ];

  meta = {
    description = "PacketFox: network-wide packet capture and path tracing";
    mainProgram = "pfox";
  };
}
