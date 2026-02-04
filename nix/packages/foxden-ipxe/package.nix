{ pkgs, ... }:
let
  ipxePkg =
    (pkgs.ipxe.override {
      embedScript = "autoexec.ipxe";
    }).overrideAttrs
      (oldAttrs: {
        src = pkgs.fetchFromGitHub {
          owner = "Doridian";
          repo = "ipxe";
          rev = "4d90e82e20336f8dfc3276d11c06eaf3bd2e41e9";
          hash = "sha256-5llmEiSdgvtWNVVKbZXTjEtbeVy/pS3WTmM1PV/3sN4=";
        };
        makeFlags = oldAttrs.makeFlags ++ [
          "TRUST=ca.crt,netboot.xyz.1.crt,netboot.xyz.2.crt"
        ];
      });
in
ipxePkg
