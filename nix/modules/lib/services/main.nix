{ nixpkgs, foxDenLib, ... }:
let
  mkEtcPaths = (paths: nixpkgs.lib.flatten (
    map (path: [
      ("-/etc/" + path)
      ("-/etc/static/" + path)
    ]) paths
  ));

  mkNamed = (svc: { svcConfig, overrideHost ? null, pkgs, config, devices ? [], gpu ? false, ... }:
  let
    cfgHostName = if overrideHost != null then overrideHost else svcConfig.host;

    host = foxDenLib.hosts.getByName config cfgHostName;

    dependency = if cfgHostName != "" then [ host.unit ] else [];
    resolvConf = if cfgHostName != "" then host.resolvConf else "/etc/resolv.conf";

    canGpu = let
      pkgEval = builtins.tryEval (config.hardware.graphics.package or null);
      pkgOk = pkgEval.success && pkgEval.value != null;
    in gpu && pkgOk;

    gpuPackages = if canGpu then [
      config.hardware.graphics.package
    ] ++ config.hardware.graphics.extraPackages else [];
    gpuPaths = if canGpu then [
      "-/run/opengl-driver"
      "-/run/opengl-driver-32"
    ] else [];

    allDevices = devices ++ (if canGpu then config.foxDen.services.gpuDevices else []);
  in
  {
    configDir = "/etc/foxden/services/${svc}";

    config = {
      systemd.services.${svc} = {
        confinement.enable = true;
        confinement.packages = [
          pkgs.cacert
        ] ++ gpuPackages;

        requires = dependency;
        bindsTo = dependency;
        after = dependency;

        serviceConfig = {
          NetworkNamespacePath = nixpkgs.lib.mkIf (cfgHostName != "") host.namespacePath;
          DevicePolicy = nixpkgs.lib.mkForce "closed";
          PrivateDevices = nixpkgs.lib.mkForce true;
          ProtectProc = "invisible";
          Restart = nixpkgs.lib.mkDefault "always";

          DeviceAllow = map (dev: "${dev} rw") allDevices;
          BindPaths = map (dev: "-${dev}") allDevices;

          BindReadOnlyPaths = let
            certBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          in [
            "/run/systemd/notify"
            pkgs.cacert
            "${resolvConf}:/etc/resolv.conf"
            "${certBundle}:/etc/ssl/certs/ca-bundle.crt"
            "${certBundle}:/etc/pki/tls/certs/ca-bundle.crt"
            "${certBundle}:/etc/ssl/certs/ca-certificates.crt"
            "${certBundle}:/etc/pki/tls/certs/ca-certificates.crt"
          ] ++ gpuPaths ++ mkEtcPaths [
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
  });
in
{
  mkOptions = { name, svcName }: {
    enable = nixpkgs.lib.mkEnableOption name;
    host = nixpkgs.lib.mkOption {
      type = nixpkgs.lib.types.str;
    };
  };

  mkEtcPaths = mkEtcPaths;

  make = inputs: mkNamed inputs.name inputs;
  mkNamed = mkNamed;

  nixosModule = { ... }:
  {
    config.environment.persistence."/nix/persist/foxden/services" = {
      hideMounts = true;
      directories = [
        { directory = "/var/lib/private"; user = "root"; group = "root"; mode = "u=rwx,g=,o="; }
        { directory = "/var/cache/private"; user = "root"; group = "root"; mode = "u=rwx,g=,o="; }
        { directory = "/var/lib/foxden"; user = "root"; group = "root"; mode = "u=rwx,g=,o="; }
      ];
    };

    options.foxDen.services.gpuDevices = nixpkgs.lib.mkOption {
      type = nixpkgs.lib.types.listOf nixpkgs.lib.types.str;
      default = [ ];
    };
  };
}
