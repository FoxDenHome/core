{
  rootDiskSize = "64G";
  # TODO: Reattach via udev AND "virsh attach-device VM_NAME FILE"
  devices.usb = [
    {
      # ZigBee USB stick
      vendorId = "1a86";
      productId = "55d4";
    }
    {
      # CC1101 stick (433 MHz)
      vendorId = "0403";
      productId = "6001";
    }
    {
      # Z-Wave USB stick
      vendorId = "10c4";
      productId = "ea60";
    }
    {
      # Internal WiFi Bluetooth USB sub-device
      vendorId = "0e8d";
      productId = "c616";
    }
  ];
  autostart = true;
  interfaces.default = {
    dns = {
      fqdns = [ "homeassistant.foxden.network" ];
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
