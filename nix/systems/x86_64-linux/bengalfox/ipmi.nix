{ ... }:
{
  config.foxDen.ipmiconfig = {
    enable = true;
    network = {
      mac = "00:25:90:FF:CF:5B";
      ipv4 = {
        address = "10.1.12.1/16";
        gateway = "10.1.0.1";
        dns = "10.1.0.53";
      };
      ipv6 = {
        address  = "fd2c:f4cb:63be:1::c01/64";
        #gateway = "fd2c:f4cb:63be:1::1"; ignore for IPv6
        dns = "fd2c:f4cb:63be:1::35";
      };
    };
  };
}
