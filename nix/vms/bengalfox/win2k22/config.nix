{
  rootDiskSize = "80G";
  autostart = true;
  sriovMappings.default = {
    addr = "0000:81:03.7";
    vlan = 0;
  };
  interfaces.default = {
    dns = {
      name = "bengalfox-win.foxden.network";
    };
    mac = "5e:8c:f2:cd:c8:4a";
    dhcpv6 = {
      duid = "0x000100013078e51e5e8cf2cdc84a";
      iaid = 451288365;
    };
    addresses = [
      "10.2.10.10/16"
      "fd2c:f4cb:63be:2::a0a/64"
    ];
  };
}
