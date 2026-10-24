{ ... }:
{
  foxDen.vms.homeassistant = {
    rootDiskSize = "64G";
    hardware = {
      uuid = "eb80bf4d-b2e5-49c3-9e4a-8bde379b8353";
      memory = "4G";
      smp = "4";
      diskType = "scsi";
      network.default = {
        type = "macvtap";
        parent = "ens1np0";
      };
    };
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
      {
        # SNDWAY SW-525B
        vendorId = "0483";
        productId = "5750";
      }
    ];
    devices.pci = [
      {
        # MT7922 WiFi
        host = "0000:04:00.0";
      }
    ];
  };

  foxDen.hosts.hosts.homeassistant = {
    webservice.enable = true;
    interfaces.default = {
      dns = {
        fqdns = [ "homeassistant.foxden.network" ];
        dynDns = true;
      };
      webservice.enable = true;
      mac = "52:54:00:e9:7e:50";
      addresses = [
        "10.2.12.2/16"
      ];
    };
  };
}
