{ ... }:
{
  config.foxDen.hosts.hosts =
    let
      mkHost = (
        name: mac: idx: {
          interfaces.default = {
            driver.name = "null";
            dns.fqdns = [ "${name}.foxden.network" ];
            inherit mac;
            addresses = [ "10.2.12.${toString idx}/16" ];
          };
        }
      );
    in
    {
      amp-living-room = mkHost "amp-living-room" "EC:F4:51:D0:8C:AF" 10;
      ecoflow-delta-pro = mkHost "ecoflow-delta-pro" "4C:EB:D6:D6:3C:9C" 31;
      hue = mkHost "hue" "C4:29:96:B5:2B:8F" 1;
      hue-sync-box = mkHost "hue-sync-box" "C4:29:96:0B:9C:82" 18;
      nanoleaf-lines-wizzy = mkHost "nanoleaf-lines-wizzy" "80:8A:F7:03:55:58" 19;
      printer = mkHost "printer" "64:C6:D2:E5:91:45" 3;
      tesla-wall-charger = mkHost "tesla-wall-charger" "98:ED:5C:9B:79:CF" 16;
      washing-machine = mkHost "washing-machine" "88:57:1D:85:70:9A" 5;
      dryer = mkHost "dryer" "88:57:1D:85:70:A1" 6;
      dishwasher = mkHost "dishwasher" "64:CB:E9:D7:B5:89" 7;
      switchbot-hub = mkHost "switchbot-hub" "24:EC:4A:8D:3A:38" 8;
      vacuum-robot = mkHost "vacuum-robot" "50:F1:4A:6D:81:0D" 9;
      nest-thermostat = mkHost "nest-thermostat" "64:16:66:9F:DE:CA" 11;
      zen-nixie-clock = mkHost "zen-nixie-clock" "E0:4F:43:C2:BA:C2" 12;
      apple-tv-den = mkHost "apple-tv-den" "9C:3E:53:1C:20:C0" 13;
      apple-tv-living-room = mkHost "apple-tv-living-room" "58:D3:49:E4:02:2D" 14;
      thotmobile = mkHost "thotmobile" "CC:88:26:27:41:29" 17;
      homepod-bedroom = mkHost "homepod-bedroom" "94:EA:32:84:DB:90" 20;
      homepod-den-right = mkHost "homepod-den-right" "F4:34:F0:4B:87:1A" 21;
      homepod-dori-office = mkHost "homepod-dori-office" "04:99:B9:66:DE:D0" 22;
      homepod-living-room = mkHost "homepod-living-room" "AC:BC:B5:D0:56:AE" 23;
    };
}
