{ ... }:
{
  # ESPHome devices (HomeAssistant/config, esphome/*.yaml) live in 10.2.13.0/16
  config.foxDen.hosts.hosts =
    let
      mkHost = (
        name: mac: idx: {
          interfaces.default = {
            driver.name = "null";
            dns.fqdns = [ "${name}.foxden.network" ];
            inherit mac;
            addresses = [ "10.2.13.${toString idx}/16" ];
          };
        }
      );
    in
    {
      custom-linescope = mkHost "custom-linescope" "58:E6:C5:68:92:A4" 1;
      led-strip-dori-office-ceiling = mkHost "led-strip-dori-office-ceiling" "C4:DE:E2:B2:D2:C7" 2;
      airgradient-bedroom = mkHost "airgradient-bedroom" "94:B5:55:2D:82:54" 3;
      airgradient-den = mkHost "airgradient-den" "0C:B8:15:C4:B3:74" 4;
      airgradient-dori-office = mkHost "airgradient-dori-office" "94:B5:55:2D:78:08" 5;
      airgradient-living-room = mkHost "airgradient-living-room" "0C:B8:15:D8:B8:EC" 6;
      airgradient-wizzy-office = mkHost "airgradient-wizzy-office" "0C:B8:15:C4:B8:D0" 7;
      custom-clock-nixie-dori = mkHost "custom-clock-nixie-dori" "C4:5B:BE:63:3A:2E" 8;
      custom-current-clamp-main = mkHost "custom-current-clamp-main" "40:91:51:51:D0:A6" 9;
      custom-garage-door = mkHost "custom-garage-door" "4C:EB:D6:0B:80:73" 10;
      custom-shaving-mirror = mkHost "custom-shaving-mirror" "44:17:93:16:03:94" 11;
      custom-streamdeck = mkHost "custom-streamdeck" "9C:13:9E:D7:02:70" 12;
      uplift-den-desk = mkHost "uplift-den-desk" "40:91:51:45:98:06" 13;
      uplift-dori-desk = mkHost "uplift-dori-desk" "40:91:51:51:E8:B6" 14;
      uplift-wizzy-desk = mkHost "uplift-wizzy-desk" "40:91:51:52:11:F7" 15;
      upsmon-living-room = mkHost "upsmon-living-room" "80:F1:B2:D6:8B:33" 16;
    };
}
