{ lib, foxDenLib, ... }:
let
  mkEtcPaths = (
    paths:
    lib.flatten (
      map (path: [
        ("-/etc/" + path)
        ("-/etc/static/" + path)
      ]) paths
    )
  );

  headOrNull = list: if list == [ ] then null else lib.lists.head list;

  getPrimaryInterfaceHost =
    config: host:
    let
      hostCfg = foxDenLib.hosts.getByName config host;
    in
    headOrNull (lib.attrsets.attrValues hostCfg.interfaces);

  getPrimaryInterface = config: svcConfig: getPrimaryInterfaceHost config svcConfig.host;

  getFirstFQDNHost =
    config: host:
    let
      primaryInterface = getPrimaryInterfaceHost config host;
    in
    headOrNull (primaryInterface.dns.fqdns);

  getFirstFQDN = config: svcConfig: getFirstFQDNHost config svcConfig.host;

  mkNamed = (
    svc:
    {
      svcConfig,
      overrideHost ? null,
      pkgs,
      config,
      devices ? [ ],
      gpu ? false,
      ...
    }:
    let
      cfgHostName = if overrideHost != null then overrideHost else svcConfig.host;

      host = foxDenLib.hosts.getByName config cfgHostName;

      dependency = if cfgHostName != "" then [ host.unit ] else [ ];
      resolvConf = if cfgHostName != "" then host.resolvConf else "/etc/resolv.conf";

      canGpu =
        let
          pkgEval = builtins.tryEval (config.hardware.graphics.package or null);
          pkgOk = pkgEval.success && pkgEval.value != null;
        in
        gpu && pkgOk;

      gpuPackages =
        if canGpu then
          [
            config.hardware.graphics.package
          ]
          ++ config.hardware.graphics.extraPackages
        else
          [ ];
      gpuPaths =
        if canGpu then
          [
            "-/run/opengl-driver"
            "-/run/opengl-driver-32"
          ]
          ++ config.foxDen.services.gpu.paths
        else
          [ ];

      allDevices = devices ++ (if canGpu then config.foxDen.services.gpu.devices else [ ]);
    in
    {
      configDir = "/etc/foxden/services/${svc}";

      config = {
        systemd.services.${svc} = {
          confinement.enable = true;
          confinement.packages = [
            pkgs.cacert
          ]
          ++ gpuPackages;

          requires = dependency;
          bindsTo = dependency;
          after = dependency;

          environment = if canGpu then config.foxDen.services.gpu.environment else { };
          startLimitIntervalSec = lib.mkForce 0;

          serviceConfig = {
            NetworkNamespacePath = lib.mkIf (cfgHostName != "") host.namespacePath;
            ProtectProc = "invisible";
            ProtectHostname =
              let
                hostFQDN = getFirstFQDNHost config cfgHostName;
              in
              if cfgHostName != "" && hostFQDN != null then "yes:${hostFQDN}" else "yes";

            Restart = lib.mkDefault "always";
            RestartSec = lib.mkForce "1s";
            RestartMaxDelaySec = lib.mkForce "5m";
            RestartSteps = lib.mkForce 10;

            DevicePolicy = lib.mkForce "closed";
            PrivateDevices = lib.mkForce true;
            DeviceAllow = map (dev: "${dev} rw") allDevices;
            BindPaths = map (dev: "-${dev}") allDevices;

            BindReadOnlyPaths =
              let
                certBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
              in
              [
                "/run/systemd/notify"
                pkgs.cacert
                "${resolvConf}:/etc/resolv.conf"
                "${certBundle}:/etc/ssl/certs/ca-bundle.crt"
                "${certBundle}:/etc/pki/tls/certs/ca-bundle.crt"
                "${certBundle}:/etc/ssl/certs/ca-certificates.crt"
                "${certBundle}:/etc/pki/tls/certs/ca-certificates.crt"
              ]
              ++ gpuPaths
              ++ mkEtcPaths [
                "hosts"
                "localtime"
                "locale.conf"
                "passwd"
                "group"
                "subuid"
                "subgid"
              ];
          };
        };
      };
    }
  );
in
{
  inherit
    mkNamed
    mkEtcPaths
    getPrimaryInterface
    getFirstFQDN
    ;

  mkOptions =
    { name, ... }:
    {
      enable = lib.mkEnableOption name;
      host = lib.mkOption {
        type = lib.types.str;
      };
    };

  make = inputs: mkNamed inputs.name inputs;

  nixosModule =
    { ... }:
    {
      config.environment.persistence."/nix/persist/foxden/services" = {
        hideMounts = true;
        directories = [
          {
            directory = "/var/lib/private";
            user = "root";
            group = "root";
            mode = "u=rwx,g=,o=";
          }
          {
            directory = "/var/cache/private";
            user = "root";
            group = "root";
            mode = "u=rwx,g=,o=";
          }
          {
            directory = "/var/lib/foxden";
            user = "root";
            group = "root";
            mode = "u=rwx,g=,o=";
          }
        ];
      };

      options.foxDen.services.gpu = {
        devices = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
        paths = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
        environment = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
        };
      };
    };
}
