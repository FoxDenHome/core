{ hostName, ... }:
{
  config = {
    services.smartd = {
      enable = true;
      notifications.mail = {
        enable = true;
        sender = "${hostName}@foxden.network";
        recipient = "alerts@doridian.net";
        mailer = "/run/wrappers/bin/sendmail";
      };
    };
  };
}
