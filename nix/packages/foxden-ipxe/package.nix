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
    arch: hasWimboot:
    let
      base = getPkg "ipxe" arch;
      wimboot = if hasWimboot then getPkg "wimboot" arch else null;
    in
    base.overrideAttrs (oldAttrs: {
      makeFlags = oldAttrs.makeFlags ++ [
        "EMBED=${./autoexec.ipxe}"
      ];
      postInstall =
        (if wimboot != null then "cp ${wimboot}/share/wimboot/*.efi $out/wimboot.efi\n" else "")
        + ''
          mv $out ${arch}
          mkdir $out
          mv ${arch} $out/
        '';
    });
in
pkgs.symlinkJoin {
  name = "foxden-ipxe";
  paths = [
    (ipxePkg "x86_64" true)
    (ipxePkg "aarch64" false)
  ];
}
