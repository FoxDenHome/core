{ ... }:
{
  config.nix = {
    daemonCPUSchedPolicy = "idle";
    daemonIOSchedClass = "idle";
    gc = {
      automatic = true;
      dates = [ "*-*-01 05:00:00" ];
      randomizedDelaySec = "4h";
    };
    optimise = {
      automatic = true;
      dates = [ "*-*-04 05:00:00" ];
      randomizedDelaySec = "4h";
    };
    settings = {
      keep-derivations = true;
      keep-outputs = true;
      auto-optimise-store = true;
    };
  };
}
