{
  foxDenLib,
  pkgs,
  lib,
  dns,
  config,
  systemArch,
  ...
}:
let
  services = foxDenLib.services;

  concatMXRecords =
    horizon:
    lib.filter (record: record.type == "MX") (
      builtins.concatLists (lib.attrValues dns.records.${horizon})
    );
  mergedRecords = (concatMXRecords "internal") ++ (concatMXRecords "external");
  mxRecordCommands = lib.naturalSort (
    lib.uniqueStrings (
      map (record: "add_record '${record.zone}' '${lib.removeSuffix "." record.value}'") mergedRecords
    )
  );
  stsManagedZones = lib.naturalSort (
    lib.attrNames (lib.filterAttrs (_: zone: zone.email != null && zone.email != "arcticfox") dns.zones)
  );

  buildScript = ''
    set -euo pipefail
    export PATH="$PATH:${pkgs.coreutils}/bin"
    add_record() {
      local file="$out/mta-sts.$1.txt"
      local mx="$2"
      if [ ! -f "$file" ]; then
        printf 'version: STSv1\r\n' > "$file"
        printf 'mode: enforce\r\n' >> "$file"
        printf 'max_age: 604800\r\n' >> "$file"
      fi
      printf "mx: $mx\r\n" >> "$file"
    }
    mkdir $out
    ${lib.concatStringsSep "\n" mxRecordCommands}
  '';
  files = derivation {
    name = "mta-sts-server-files";
    builder = pkgs.writeShellScript "builder.sh" buildScript;
    args = [ ];
    system = systemArch;
  };
  policyId = builtins.substring 0 32 (
    builtins.convertHash {
      hash = builtins.hashString "sha256" "${buildScript}";
      hashAlgo = "sha256";
      toHashFormat = "nix32";
    }
  );

  svcConfig = config.foxDen.services.mta-sts-server;
in
{
  options.foxDen.services.mta-sts-server = {
    filesPackage = lib.mkOption {
      type = lib.types.package;
      default = files;
      readOnly = true;
    };
    fqdns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = map (zone: "mta-sts.${zone}") stsManagedZones;
      readOnly = true;
    };
  }
  // (services.http.mkOptions {
    name = "mta-sta webserver";
  });

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "mta-sts-server";
        extraHttpConfig =
          { ... }:
          ''
            map $http_host $file_host {
                default $http_host;
                '''      $host;
            }
          '';
        extraConfig =
          { ... }:
          ''
            location = /.well-known/mta-sts.txt {
              default_type text/plain;
              types { }
              alias /files/$file_host.txt;
            }
          '';
        target = "return 404;";
      }).config
      {
        foxDen.dns.records = map (zone: {
          fqdn = "_mta-sts.${zone}";
          type = "TXT";
          ttl = 3600;
          value = "v=STSv1; id=${policyId};";
          horizon = "*";
        }) stsManagedZones;

        systemd.services.mta-sts-server = {
          serviceConfig = {
            BindReadOnlyPaths = [
              "${files}:/files"
            ];
          };
        };
      }
    ]
  );
}
