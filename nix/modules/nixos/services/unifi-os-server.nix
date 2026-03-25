{
  config,
  lib,
  pkgs,
  foxDenLib,
  ...
}:
let
  svcConfig = config.foxDen.services.unifi-os-server;
  stateDir = config.users.users.unifi-os-server.home;

  # Capture unifi-core stdout/stderr to readable files
  # (the container's journal is only accessible as root)
  ucoreDebug = pkgs.writeText "unifi-core-debug.conf" ''
    [Service]
    StandardOutput=append:/data/unifi-core/logs/stdout.log
    StandardError=append:/data/unifi-core/logs/stderr.log
  '';

  # Fix missing directories that services expect but don't create on first run.
  ucorePreStartFix = pkgs.writeText "unifi-core-prestart-fix.conf" ''
    [Service]
    ExecStartPre=-/bin/mkdir -p /data/unifi-core/config/http
    ExecStartPre=-/bin/mkdir -p /var/log/nginx
  '';

  # MongoDB needs writable log and data dirs; + runs as root regardless of User=
  mongoPreStartFix = pkgs.writeText "mongodb-prestart-fix.conf" ''
    [Service]
    ExecStartPre=+/bin/bash -c "mkdir -p /var/log/mongodb && chown mongodb:mongodb /var/log/mongodb /var/lib/mongodb"
  '';
in
{
  # reverse engineered via
  # https://www.unihosted.com/blog/running-unifi-os-server-in-docker
  options.foxDen.services.unifi-os-server = {
  }
  // (foxDenLib.services.oci.mkOptions {
    svcName = "unifi-os-server";
    name = "UniFi OS Server";
  });

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (foxDenLib.services.oci.make {
        inherit pkgs config svcConfig;
        name = "unifi-os-server";
        oci = {
          privileged = true;
          image = pkgs.unifi-os-server-image.tag;
          imageFile = pkgs.unifi-os-server-image;
          pull = "never";
          volumes = [
            "${stateDir}/persistent:/persistent"
            "${stateDir}/log:/var/log"
            "${stateDir}/data:/data"
            "${stateDir}/srv:/srv"
            "${stateDir}/unifi:/var/lib/unifi"
            "${stateDir}/mongodb:/var/lib/mongodb"
            "${ucoreDebug}:/etc/systemd/system/unifi-core.service.d/debug.conf:ro"
            "${ucorePreStartFix}:/etc/systemd/system/unifi-core.service.d/prestart-fix.conf:ro"
            "${mongoPreStartFix}:/etc/systemd/system/mongodb.service.d/prestart-fix.conf:ro"
          ];
          environment = {
            UOS_SYSTEM_IP = "127.0.0.1";
            UOS_SERVER_VERSION = pkgs.unifi-os-server-image.version;
            FIRMWARE_PLATFORM = if pkgs.stdenv.hostPlatform.isAarch64 then "linux-arm64" else "linux-x64";
          };
          extraOptions = [
            "--systemd=always"
          ];
        };
        systemd = {
          preStart = lib.mkAfter ''
            ${pkgs.coreutils}/bin/mkdir -p ${stateDir}/{persistent,log,data,srv,unifi,mongodb}

            uuid_file="${stateDir}/data/uos_uuid"
            if [ ! -f "$uuid_file" ]; then
              ${pkgs.coreutils}/bin/touch "$uuid_file"
            fi
            # The Java UniFi controller requires exactly UUID v5 (SHA-1 name-based).
            # Generate a stable v5 UUID derived from the machine-id.
            if ! ${pkgs.gnugrep}/bin/grep -qP '^[0-9a-f]{8}-[0-9a-f]{4}-5' "$uuid_file" 2>/dev/null; then
              ${pkgs.util-linux}/bin/uuidgen -s -n @dns -N "$(${pkgs.coreutils}/bin/cat /etc/machine-id)" > "$uuid_file"
            fi
          '';
          serviceConfig = {
            ProtectControlGroups = "private";
          };
        };
      }).config
      {
        # # https://www.crosstalksolutions.com/complete-unifi-os-server-installation-on-linux-best-practices/
        # networking.firewall = mkIf svcConfig.openFirewall {
        #   allowedTCPPorts = [
        #     443 # HTTPS portal
        #     8080 # UAP device inform
        #     8443 # Controller HTTPS
        #     8843 # HTTPS portal redirect
        #     8880 # HTTP portal redirect
        #     6789 # Mobile speed test
        #   ];
        #   allowedUDPPorts = [
        #     3478 # STUN
        #     10001 # Device discovery
        #   ];
        # };
      }
    ]
  );
}
