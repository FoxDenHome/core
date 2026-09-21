{
  pkgs,
  systemArch,
  ...
}:
let
  getPkg =
    name: arch:
    if systemArch == "${arch}-linux" then
      pkgs.${name}
    else
      pkgs.pkgsCross."${arch}-multiplatform".${name};

  ipxePkg =
    arch:
    let
      base = getPkg "ipxe" arch;
    in
    base.overrideAttrs (oldAttrs: {
      makeFlags = oldAttrs.makeFlags ++ [
        "EMBED=${./autoexec.ipxe}"
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
