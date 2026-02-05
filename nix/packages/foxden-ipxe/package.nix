{
  pkgs,
  systemArch,
  lib,
  ...
}:
let
  ipxePkg =
    arch:
    let
      base =
        if systemArch == "${arch}-linux" then pkgs.ipxe else pkgs.pkgsCross."${arch}-multiplatform".ipxe;
    in
    base.overrideAttrs (oldAttrs: {
      src = pkgs.fetchFromGitHub {
        owner = "Doridian";
        repo = "ipxe";
        rev = "4d90e82e20336f8dfc3276d11c06eaf3bd2e41e9";
        hash = "sha256-5llmEiSdgvtWNVVKbZXTjEtbeVy/pS3WTmM1PV/3sN4=";
      };
      makeFlags = oldAttrs.makeFlags ++ [
        "EMBED=${./autoexec.ipxe}"
        "TRUST=${
          lib.concatStringsSep "," (
            map (n: "${./certs}/${n}") (lib.attrsets.attrNames (builtins.readDir ./certs))
          )
        }"
      ];
      postInstall = ''
        mv $out ${arch}
        mkdir $out
        mv ${arch} $out/
      '';
    });
in
pkgs.symlinkJoin {
  name = "foxden-ipxe";
  paths = [
    (ipxePkg "x86_64")
    (ipxePkg "aarch64")
  ];
}
