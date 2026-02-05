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
      makeFlags = oldAttrs.makeFlags ++ [
        "EMBED=${./autoexec.ipxe}"
        "TRUST=${
          lib.concatStringsSep "," (
            map (n: "${./certs}/${n}") (lib.attrsets.attrNames (builtins.readDir ./certs))
          )
        }"
      ];
      preConfigure = ''
        patch -p1 -i ${./dont-unregister-shim.patch}
      '';
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
