{
  rootDiskSize = "64G";
  # TODO: Reattach via udev AND "virsh attach-device VM_NAME FILE" AND
  # <hostdev mode='subsystem' type='usb' managed='yes'>
  #   <source>
  #     <vendor id='${dev.vendorId}'/>
  #     <product id='${dev.productId}'/>
  #   </source>
  # </hostdev>
  devices.usb = [
    {
      # ZigBee USB stick
      vendorId = "0x1a86";
      productId = "0x55d4";
    }
    {
      # CC1101 stick (433 MHz)
      vendorId = "0x0403";
      productId = "0x6001";
    }
    {
      # Z-Wave USB stick
      vendorId = "0x10c4";
      productId = "0xea60";
    }
    {
      # Internal WiFi Bluetooth USB sub-device
      vendorId = "0x0e8d";
      productId = "0xc616";
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
