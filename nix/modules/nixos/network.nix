{ ... }:
{
  config = {
    boot = {
      kernel.sysctl = {
        "net.ipv4.tcp_congestion_control" = "bbr";
        "net.ipv4.tcp_syncookies" = true;
        "net.ipv4.tcp_fastopen" = 3;
        "net.ipv4.tcp_tw_reuse" = true;
        "net.ipv4.tcp_fin_timeout" = 10;
        "net.ipv4.tcp_slow_start_after_idle" = false;
        "net.ipv4.tcp_sack" = true;
        "net.ipv4.tcp_rfc1337" = true;
        "net.ipv4.tcp_max_tw_buckets" = 2000000;
        "net.ipv4.tcp_rmem" = "4096 262144 180000000";
        "net.ipv4.tcp_wmem" = "4096 24576 180000000";
        "net.ipv4.tcp_keepalive_time" = 60;
        "net.ipv4.tcp_keepalive_intvl" = 10;
        "net.ipv4.tcp_keepalive_probes" = 6;
        "net.ipv4.ip_unprivileged_port_start" = 80;
        "net.core.default_qdisc" = "fq_codel";
      };
      kernelModules = [ "tcp_bbr" ];
    };
    services.resolved = {
      enable = true;
      llmnr = "false";
      dnssec = "allow-downgrade";
      domains = [
        "foxden.network"
      ];
    };
  };
}
