{
  config,
  lib,
  pkgs,
  hostName,
  ...
}:
let
  cfg = config.foxDen.packetfox.agent;
  pubkey = lib.trim (builtins.readFile ../../files/packetfox/pfox_ed25519.pub);
in
{
  # PacketFox (pfox on islandfox) logs in as pfox and can only run
  # pfox-agent, which lists interfaces and runs tcpdump in any netns.
  options.foxDen.packetfox.agent = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.foxDen.deploy.push.enable;
      description = "Let PacketFox capture packets on this host";
    };
    interface = lib.mkOption {
      type = lib.types.str;
      default = config.foxDen.deploy.push.interface;
      description = "The interface PacketFox reaches this host's SSH on";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.pfox = {
      isSystemUser = true;
      group = "pfox";
      home = "/var/empty";
      # sshd runs the forced command through the login shell
      shell = pkgs.bashInteractive;
      openssh.authorizedKeys.keys = [
        "command=\"${config.security.wrapperDir}/pfox-agent\",restrict ${pubkey}"
      ];
    };
    users.groups.pfox = { };

    security.wrappers.pfox-agent = {
      source = "${pkgs.packetfox}/bin/pfox-agent";
      owner = "root";
      group = "pfox";
      permissions = "u+rx,g+x";
      # Raised into the ambient set. pfox-agent keeps CAP_SYS_ADMIN (setns)
      # and CAP_SYS_PTRACE (opening /proc/<pid>/ns/net of units with their
      # own netns, like nsenter) to itself and hands tcpdump only the
      # other two.
      capabilities = "cap_net_raw,cap_net_admin,cap_sys_admin,cap_sys_ptrace+p";
    };

    foxDen.firewall.rules = [
      {
        table = "filter";
        chain = "forward";
        action = "accept";
        source = {
          host = "packetfox";
          system = "islandfox";
        };
        gateway = "router";
        destination = {
          host = hostName;
          inherit (cfg) interface;
        };
        dstport = 22;
        protocol = "tcp";
        comment = "packetfox-agent-ssh";
      }
    ];
  };
}
