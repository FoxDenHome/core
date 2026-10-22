{ ... }:
{
  # OpenTofu state backend for terraform/, reached over SSH by terraform/tf.sh
  foxDen.services.postgresql = {
    enable = true;
    groupSockets = [
      {
        database = "opentofu";
        group = 4269; # kanidm superadmins
      }
    ];
  };
}
