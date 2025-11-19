{
  rootDiskSize = "64G";
  autostart = true;
  interfaces.default = {
    dns = {
      fqdn = "homeassistant.foxden.network";
      dynDns = true;
    };
    webservice.enable = true;
    mac = "52:54:00:e9:7e:50";
    dhcpv6 = {
      duid = "0x000412082c467ead763e36f522f36b41abed";
      iaid = 1555819358;
    };
    addresses = [
      "10.2.12.2/16"
      "fd2c:f4cb:63be:2::c02/64"
    ];
  };
  webservice.enable = true;
}
