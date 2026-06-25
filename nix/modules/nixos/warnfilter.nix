{ lib, config, ... }:
{
  options.warnings = lib.mkOption {
    apply =
      defns:
      lib.filter (
        raw:
        let
          msg = lib.trim raw;
        in
        !lib.any (pattern: builtins.match pattern msg != null) config.foxDen.hideWarnings
      ) defns;
  };

  options.foxDen.hideWarnings = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = ''
      List of warnings to hide. This is useful for hiding warnings that are
      known to be false positives or otherwise not relevant to the user.
      Matched using builtins.match after lib.trim
    '';
  };
}
