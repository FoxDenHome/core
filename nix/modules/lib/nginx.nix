{ nixpkgs, ... }:
rec {
  mkProxiesText =
    prefix: config:
    "${prefix}real_ip_header proxy_protocol;\n"
    + nixpkgs.lib.concatStringsSep "\n" (
      map (ip: "${prefix}set_real_ip_from ${ip};") config.foxDen.services.trustedProxies
    );
  mkProxiesConf = config: builtins.toFile "proxies.conf" (mkProxiesText "" config);
}
