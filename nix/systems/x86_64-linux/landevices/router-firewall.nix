{ lib, foxDenLib, ... }:
let
  baseRule = {
    table = "filter";
    chain = "forward";
    action = "accept";
  };
in
{
  foxDen.firewall.rules = lib.flatten (
    map (
      rule:
      if (foxDenLib.util.isIPv4 rule.source) then
        [
          (
            rule
            // baseRule
            // {
              destination = "10.99.0.0/16";
            }
          )
          (
            rule
            // baseRule
            // {
              destination = "172.17.0.0/16";
            }
          )
        ]
      else
        [
          (
            rule
            // baseRule
            // {
              destination = "fd2c:f4cb:63be::a00:0/104";
            }
          )
          (
            rule
            // baseRule
            // {
              destination = "fd2c:f4cb:63be::ac00:0/104";
            }
          )
        ]
    ) (foxDenLib.firewall.templates.trusted "s2s-network")
  );
}
